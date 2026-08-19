<#
.SYNOPSIS
    Registers the data sources listed in an export that are missing from the target instance.

.DESCRIPTION
    Compares the sources in the file against the target by FQDN and registers the missing ones
    against the collector you nominate, using a credential you supply at run time.

    Credentials are never carried in the export, so -SourceCredential is required and is used
    for every source in the run. Register sources that share a credential together; run the
    script again for the next set.

    Pain area addressed: #16 Config portability between environments.

.PARAMETER Server
    FQDN or IP address of the VCF Operations for Networks platform appliance.

.PARAMETER Credential
    Credential used to authenticate to the Networks API.

.PARAMETER InputPath
    Path to the .json (preferred) or .csv file written by the matching Export-* script. The
    envelope is validated before anything is changed.

.PARAMETER SourceCredential
    Credential used to register the data sources in this run.

.PARAMETER ProxyId
    Collector or proxy node id to attach the sources to. Omit to reuse the proxy id recorded in
    the file.

.PARAMETER SourceType
    Limit the import to these data source types.

.PARAMETER IgnoreInvalidCertificate
    Accept an untrusted or self-signed certificate on the target endpoint. Use only in lab
    environments.

.PARAMETER DiffOnly
    Show the planned changes and exit without applying any of them. Use this first, every time.

.EXAMPLE
    PS> ./Import-NetworksDataSource.ps1 -Server networks2.example.local -Credential $cred -InputPath ./sources.json -SourceCredential $vcCred -DiffOnly

    Shows which data sources would be registered.

.NOTES
    Author        : Sampath
    Product       : Aria Operations for Networks (VCF 5.x)
    Target        : VMware Cloud Foundation 5.x
    Modules       : None (uses Invoke-RestMethod)
    Behaviour     : Changes the target. Supports -WhatIf, -Confirm and -DiffOnly.
    Standalone    : Yes. This script does not dot-source or import any other file
                    in this repository and can be copied out on its own.
#>

#Requires -Version 5.1

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Server,
    [Parameter(Mandatory)] [System.Management.Automation.PSCredential]$Credential,
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$InputPath,
    [Parameter(Mandatory)] [System.Management.Automation.PSCredential]$SourceCredential,
    [Parameter()] [string]$ProxyId,
    [Parameter()] [string[]]$SourceType,
    [Parameter()] [switch]$IgnoreInvalidCertificate,
    [Parameter()] [switch]$DiffOnly
)

$ErrorActionPreference = 'Stop'

function Read-ExportFile {
    <#
        Loads a .json export envelope (or a flat .csv) produced by the matching
        Export-* script and refuses to continue if it describes something else.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedSchema,
        [Parameter(Mandatory)][string]$ExpectedProduct,
        [Parameter(Mandatory)][string]$ExpectedVcfVersion
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Input file not found: $Path"
    }

    switch ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        '.json' {
            $document = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
            $names = @($document.PSObject.Properties.Name)
            if ($names -notcontains 'schema') {
                Write-Verbose 'Input has no export envelope; treating the whole document as data.'
                return @($document)
            }
            if ($document.schema -ne $ExpectedSchema) {
                throw ("Schema mismatch. File declares '{0}' but this script expects '{1}'." -f $document.schema, $ExpectedSchema)
            }
            if ($document.product -and $document.product -ne $ExpectedProduct) {
                throw ("Product mismatch. File was exported from '{0}' but this script targets '{1}'." -f $document.product, $ExpectedProduct)
            }
            if ($document.vcfVersion -and $document.vcfVersion -ne $ExpectedVcfVersion) {
                Write-Warning ("File was exported from VCF {0} but this script targets VCF {1}. Review the diff carefully." -f $document.vcfVersion, $ExpectedVcfVersion)
            }
            return @($document.data)
        }
        '.csv' {
            Write-Verbose 'CSV input carries no envelope; schema and version cannot be validated.'
            return @(Import-Csv -LiteralPath $Path)
        }
        default {
            throw "Unsupported input format. Provide the .json or .csv file written by the matching Export-* script."
        }
    }
}

function Compare-DesiredState {
    <#
        Joins the desired records from the input file against what the target
        currently has, and labels each one Create, Update or Match so the plan can
        be reviewed before a single change is committed.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowEmptyCollection()][object[]]$Current,
        [Parameter()][AllowEmptyCollection()][object[]]$Desired,
        [Parameter(Mandatory)][string]$KeyProperty,
        [Parameter()][string[]]$CompareProperty
    )

    $index = @{}
    foreach ($item in @($Current)) {
        $key = [string]$item.$KeyProperty
        if ($key) { $index[$key] = $item }
    }

    foreach ($item in @($Desired)) {
        $key = [string]$item.$KeyProperty
        if (-not $key) {
            Write-Warning "Skipping a desired record with no '$KeyProperty' value."
            continue
        }

        $existing = $index[$key]
        $changed = @()

        if ($null -eq $existing) {
            $action = 'Create'
        }
        else {
            $properties = if ($CompareProperty) { $CompareProperty } else { @($item.PSObject.Properties.Name) }
            foreach ($property in $properties) {
                if ($property -eq $KeyProperty) { continue }
                $left  = [string]$existing.$property
                $right = [string]$item.$property
                if ($left -ne $right) { $changed += $property }
            }
            $action = if ($changed.Count -gt 0) { 'Update' } else { 'Match' }
        }

        [pscustomobject]@{
            Key             = $key
            Action          = $action
            ChangedProperty = ($changed -join ', ')
            Desired         = $item
            Current         = $existing
        }
    }
}

$expectedSchema     = 'networks.data-source'
$expectedProduct    = 'vcf-operations-for-networks'
$expectedVcfVersion = '5.x'

$headers = $null
try {
    $restCommon = @{ ContentType = 'application/json' }

    if ($PSVersionTable.PSVersion.Major -lt 6) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    }

    if ($IgnoreInvalidCertificate) {
        if ($PSVersionTable.PSVersion.Major -ge 6) {
            $restCommon['SkipCertificateCheck'] = $true
        }
        else {
            Write-Warning 'Certificate validation is disabled for this session. Use this only in lab environments.'
            [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        }
    }

    $baseUri = "https://$Server"
    $authBody = @{
        username = $Credential.UserName
        password = $Credential.GetNetworkCredential().Password
        domain   = @{ domain_type = 'LOCAL' }
    } | ConvertTo-Json
    $authResponse = Invoke-RestMethod @restCommon -Method Post -Uri "$baseUri/api/ni/auth/token" -Body $authBody
    $headers = @{ Accept = 'application/json'; Authorization = "NetworkInsight $($authResponse.token)" }
    Write-Verbose "Acquired a Networks API token from $Server"

    $desired = Read-ExportFile -Path $InputPath -ExpectedSchema $expectedSchema `
        -ExpectedProduct $expectedProduct -ExpectedVcfVersion $expectedVcfVersion

    if ($SourceType) { $desired = @($desired | Where-Object { $_.SourceType -in $SourceType }) }

    $current = @()
    foreach ($type in @($desired.SourceType | Sort-Object -Unique)) {
        try {
            $listing = Invoke-RestMethod @restCommon -Method Get `
                -Uri ('{0}/api/ni/data-sources/{1}' -f $baseUri, $type) -Headers $headers
            foreach ($entry in @($listing.results)) {
                $detail = Invoke-RestMethod @restCommon -Method Get `
                    -Uri ('{0}/api/ni/data-sources/{1}/{2}' -f $baseUri, $type, $entry.entity_id) -Headers $headers
                $current += [pscustomobject]@{ Fqdn = $detail.fqdn; SourceType = $type }
            }
        }
        catch { Write-Verbose "Could not enumerate existing sources of type '$type'." }
    }

    Write-Verbose ("Input lists {0} source(s); target has {1} comparable source(s)." -f @($desired).Count, @($current).Count)

    $plan = Compare-DesiredState -Current @($current) -Desired @($desired) `
        -KeyProperty 'Fqdn' -CompareProperty @('SourceType')

    $actionable = @($plan | Where-Object { $_.Action -ne 'Match' })
    Write-Verbose ("Plan: {0} change(s), {1} already in the desired state." -f $actionable.Count, (@($plan).Count - $actionable.Count))

    if ($DiffOnly) {
        Write-Verbose '-DiffOnly was specified. Nothing was changed.'
        return $plan
    }

    if ($actionable.Count -eq 0) {
        Write-Verbose 'Everything already matches the desired state. Nothing to do.'
        return $plan
    }
    foreach ($item in ($actionable | Where-Object { $_.Action -eq 'Create' })) {
        $row = $item.Desired
        $proxy = if ($ProxyId) { $ProxyId } else { $row.ProxyId }

        if (-not $proxy) {
            Write-Warning "No proxy id for '$($item.Key)'. Pass -ProxyId. Skipping."
            [pscustomobject]@{ Source = $item.Key; Status = 'SkippedNoProxy' }
            continue
        }

        if (-not $PSCmdlet.ShouldProcess("data source '$($item.Key)' ($($row.SourceType))", 'Register')) { continue }

        try {
            $payload = @{
                fqdn        = $row.Fqdn
                proxy_id    = $proxy
                nickname    = $row.Nickname
                enabled     = $true
                credentials = @{
                    username = $SourceCredential.UserName
                    password = $SourceCredential.GetNetworkCredential().Password
                }
            } | ConvertTo-Json -Depth 6

            Invoke-RestMethod @restCommon -Method Post `
                -Uri ('{0}/api/ni/data-sources/{1}' -f $baseUri, $row.SourceType) -Headers $headers -Body $payload | Out-Null

            [pscustomobject]@{ Source = $item.Key; SourceType = $row.SourceType; Status = 'Registered' }
        }
        catch {
            Write-Warning ("Could not register '{0}': {1}" -f $item.Key, $_.Exception.Message)
            [pscustomobject]@{ Source = $item.Key; SourceType = $row.SourceType; Status = 'Failed' }
        }
    }
}
finally {
    $headers = $null
}
