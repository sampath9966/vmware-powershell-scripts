<#
.SYNOPSIS
    Creates or updates agent groups from an export, matching by group name.

.DESCRIPTION
    Creates the agent groups in the file that do not exist in the target, and updates the ones
    whose criteria or configuration block differs.

    The configuration block is applied verbatim, so a group referencing a parser that is not
    installed in the target will be created but will not collect. The content pack export and
    import scripts in this folder are the way to close that gap first.

    Pain area addressed: #9 Config drift (NTP/DNS/syslog/lockdown); #16 Config portability
    between environments.

.PARAMETER Server
    FQDN or IP address of the VCF Operations for Logs node.

.PARAMETER Credential
    Credential used to authenticate to the Logs API.

.PARAMETER InputPath
    Path to the .json (preferred) or .csv file written by the matching Export-* script. The
    envelope is validated before anything is changed.

.PARAMETER GroupName
    Limit the import to these group names.

.PARAMETER UpdateExisting
    Also update groups that exist but whose criteria or configuration differs.

.PARAMETER IgnoreInvalidCertificate
    Accept an untrusted or self-signed certificate on the target endpoint. Use only in lab
    environments.

.PARAMETER DiffOnly
    Show the planned changes and exit without applying any of them. Use this first, every time.

.EXAMPLE
    PS> ./Import-LogsAgentGroup.ps1 -Server logs2.example.local -Credential $cred -InputPath ./agentgroups.json -DiffOnly

    Shows which agent groups are missing or drifted in the target.

.NOTES
    Author        : Sampath
    Product       : Aria Operations for Logs (VCF 5.x)
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
    [Parameter()] [string[]]$GroupName,
    [Parameter()] [switch]$UpdateExisting,
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

$expectedSchema     = 'logs.agent-group'
$expectedProduct    = 'vcf-operations-for-logs'
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
    $authBody = @{ provider = 'Local'; username = $Credential.UserName; password = $Credential.GetNetworkCredential().Password } | ConvertTo-Json
    $authResponse = Invoke-RestMethod @restCommon -Method Post -Uri "$baseUri/api/v2/sessions" -Body $authBody
    $headers = @{ Accept = 'application/json'; Authorization = "Bearer $($authResponse.sessionId)" }
    Write-Verbose "Acquired a Logs API session from $Server"

    $desired = Read-ExportFile -Path $InputPath -ExpectedSchema $expectedSchema `
        -ExpectedProduct $expectedProduct -ExpectedVcfVersion $expectedVcfVersion

    if ($GroupName) { $desired = @($desired | Where-Object { $_.Name -in $GroupName }) }

    $response = Invoke-RestMethod @restCommon -Method Get -Uri "$baseUri/api/v2/agent/groups" -Headers $headers
    $current = foreach ($group in @($response.groups)) {
        [pscustomobject]@{
            Name          = $group.name
            Criteria      = ($group.criteria -replace '\s+', ' ')
            Configuration = ($group.agentConfig -replace '\s+', ' ')
            GroupId       = $group.id
        }
    }

    Write-Verbose ("Input lists {0} group(s); target has {1}." -f @($desired).Count, @($current).Count)

    $plan = Compare-DesiredState -Current @($current) -Desired @($desired) `
        -KeyProperty 'Name' -CompareProperty @('Criteria', 'Configuration')

    if (-not $UpdateExisting) {
        foreach ($item in $plan) { if ($item.Action -eq 'Update') { $item.Action = 'Match' } }
    }

    $actionable = @($plan | Where-Object { $_.Action -ne 'Match' })
    Write-Verbose ("Plan: {0} change(s), {1} already in the desired state." -f $actionable.Count, (@($plan).Count - $actionable.Count))

    if ($DiffOnly) {
        Write-Warning ("-DiffOnly was specified, so NOTHING was changed. The plan below lists " +
            "{0} pending change(s). Re-run without -DiffOnly to apply it." -f $actionable.Count)
        return $plan
    }

    if ($actionable.Count -eq 0) {
        Write-Warning 'Everything already matches the desired state. Nothing to do.'
        return $plan
    }

    Write-Verbose ("Applying {0} change(s)." -f $actionable.Count)
    foreach ($item in $actionable) {
        $row = $item.Desired
        $verb = if ($item.Action -eq 'Create') { 'Create' } else { 'Update' }

        if (-not $PSCmdlet.ShouldProcess("agent group '$($item.Key)'", $verb)) { continue }

        try {
            $payload = @{
                name        = $row.Name
                groupType   = $row.GroupType
                criteria    = $row.Criteria
                agentConfig = $row.Configuration
            } | ConvertTo-Json -Depth 6

            if ($item.Action -eq 'Create') {
                Invoke-RestMethod @restCommon -Method Post -Uri "$baseUri/api/v2/agent/groups" -Headers $headers -Body $payload | Out-Null
            }
            else {
                Invoke-RestMethod @restCommon -Method Put `
                    -Uri ('{0}/api/v2/agent/groups/{1}' -f $baseUri, $item.Current.GroupId) -Headers $headers -Body $payload | Out-Null
            }

            [pscustomobject]@{ Group = $item.Key; Action = $item.Action; Status = 'Applied' }
        }
        catch {
            Write-Warning ("Could not apply group '{0}': {1}" -f $item.Key, $_.Exception.Message)
            [pscustomobject]@{ Group = $item.Key; Action = $item.Action; Status = 'Failed' }
        }
    }
}
finally {
    $headers = $null
}
