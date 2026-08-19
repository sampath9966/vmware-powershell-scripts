<#
.SYNOPSIS
    Creates applications and tiers from an export that do not exist in the target instance.

.DESCRIPTION
    Creates each missing application and then its tiers, rebuilding search-based membership
    criteria from the exported filter text.

    Tiers built from an explicit VM list are not recreated, because VM entity ids differ between
    instances - those tiers are reported and skipped so the gap is visible rather than silently
    producing an empty tier.

    Pain area addressed: #16 Config portability between environments.

.PARAMETER Server
    FQDN or IP address of the VCF Operations for Networks platform appliance.

.PARAMETER Credential
    Credential used to authenticate to the Networks API.

.PARAMETER InputPath
    Path to the .json (preferred) or .csv file written by the matching Export-* script. The
    envelope is validated before anything is changed.

.PARAMETER ApplicationName
    Limit the import to these application names.

.PARAMETER IgnoreInvalidCertificate
    Accept an untrusted or self-signed certificate on the target endpoint. Use only in lab
    environments.

.PARAMETER DiffOnly
    Show the planned changes and exit without applying any of them. Use this first, every time.

.EXAMPLE
    PS> ./Import-NetworksApplication.ps1 -Server networks2.example.local -Credential $cred -InputPath ./apps.json -DiffOnly

    Shows which applications and tiers the target is missing.

.NOTES
    Author        : Sampath
    Product       : VCF Operations for networks (VCF 9.x)
    Target        : VMware Cloud Foundation 9.x
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
    [Parameter()] [string[]]$ApplicationName,
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

$expectedSchema     = 'networks.application'
$expectedProduct    = 'vcf-operations-for-networks'
$expectedVcfVersion = '9.x'

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

    if ($ApplicationName) { $desired = @($desired | Where-Object { $_.Application -in $ApplicationName }) }

    $existingNames = @()
    $existingIdByName = @{}
    try {
        $listing = Invoke-RestMethod @restCommon -Method Get -Uri "$baseUri/api/ni/groups/applications" -Headers $headers
        foreach ($entry in @($listing.results)) {
            $application = Invoke-RestMethod @restCommon -Method Get `
                -Uri ('{0}/api/ni/groups/applications/{1}' -f $baseUri, $entry.entity_id) -Headers $headers
            $existingNames += $application.name
            $existingIdByName[$application.name] = $entry.entity_id
        }
    }
    catch { Write-Verbose 'Could not enumerate existing applications.' }

    Write-Verbose ("Input lists {0} tier row(s); target has {1} application(s)." -f @($desired).Count, $existingNames.Count)

    $plan = @()

    foreach ($group in ($desired | Group-Object Application)) {
        if ($group.Name -notin $existingNames) {
            $plan += [pscustomobject]@{
                Key = 'app:' + $group.Name; Action = 'Create'; ChangedProperty = 'application'
                Kind = 'Application'; Application = $group.Name; Tier = ''
                Desired = $group.Group[0]; Current = $null
            }
        }

        foreach ($row in $group.Group) {
            if (-not $row.Tier) { continue }
            $plan += [pscustomobject]@{
                Key = 'tier:{0}/{1}' -f $group.Name, $row.Tier
                Action = 'Create'; ChangedProperty = 'tier'
                Kind = 'Tier'; Application = $group.Name; Tier = $row.Tier
                Desired = $row; Current = $null
            }
        }
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
    foreach ($item in ($actionable | Where-Object Kind -eq 'Application')) {
        if (-not $PSCmdlet.ShouldProcess("application '$($item.Application)'", 'Create')) { continue }

        try {
            $payload = @{ name = $item.Application } | ConvertTo-Json
            $created = Invoke-RestMethod @restCommon -Method Post -Uri "$baseUri/api/ni/groups/applications" -Headers $headers -Body $payload
            $existingIdByName[$item.Application] = $created.entity_id
            [pscustomobject]@{ Kind = 'Application'; Name = $item.Application; Status = 'Created' }
        }
        catch {
            Write-Warning ("Could not create application '{0}': {1}" -f $item.Application, $_.Exception.Message)
            [pscustomobject]@{ Kind = 'Application'; Name = $item.Application; Status = 'Failed' }
        }
    }

    foreach ($item in ($actionable | Where-Object Kind -eq 'Tier')) {
        $row = $item.Desired

        if (-not $existingIdByName.ContainsKey($item.Application)) {
            [pscustomobject]@{ Kind = 'Tier'; Name = $item.Key; Status = 'SkippedMissingApplication' }
            continue
        }

        if ($row.MembershipType -like '*VMMembershipCriteria*') {
            Write-Warning "Tier '$($item.Key)' uses an explicit VM list, whose ids do not transfer between instances. Skipping."
            [pscustomobject]@{ Kind = 'Tier'; Name = $item.Key; Status = 'SkippedVmList' }
            continue
        }

        if (-not $PSCmdlet.ShouldProcess("tier '$($item.Key)'", 'Create')) { continue }

        try {
            $filterText = ($row.Criteria -split ':\s*', 2)[-1]
            $entityType = ($row.Criteria -split ':\s*', 2)[0]

            $payload = @{
                name = $row.Tier
                group_membership_criteria = @(
                    @{
                        membership_type = 'SearchMembershipCriteria'
                        search_membership_criteria = @{
                            entity_type = $entityType
                            filter      = $filterText
                        }
                    }
                )
            } | ConvertTo-Json -Depth 8

            Invoke-RestMethod @restCommon -Method Post `
                -Uri ('{0}/api/ni/groups/applications/{1}/tiers' -f $baseUri, $existingIdByName[$item.Application]) `
                -Headers $headers -Body $payload | Out-Null

            [pscustomobject]@{ Kind = 'Tier'; Name = $item.Key; Status = 'Created' }
        }
        catch {
            Write-Warning ("Could not create tier '{0}': {1}" -f $item.Key, $_.Exception.Message)
            [pscustomobject]@{ Kind = 'Tier'; Name = $item.Key; Status = 'Failed' }
        }
    }
}
finally {
    $headers = $null
}
