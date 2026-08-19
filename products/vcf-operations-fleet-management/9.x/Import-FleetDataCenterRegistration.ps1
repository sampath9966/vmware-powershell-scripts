<#
.SYNOPSIS
    Recreates the datacenters and vCenter registrations from an export that are missing in the target.

.DESCRIPTION
    Creates any datacenter in the file that does not exist here, then registers the vCenters
    under it using a locker credential alias that must already exist in the target.

    Credentials are never carried in the export, so the alias named in the file has to be
    present in the target locker. A registration whose alias is missing is reported and skipped
    rather than created with no way to authenticate.

    Pain area addressed: #16 Config portability between environments.

.PARAMETER Server
    FQDN or IP address of the VCF Operations fleet management (Aria Suite Lifecycle) appliance.

.PARAMETER Credential
    Credential used to authenticate to the fleet management API.

.PARAMETER InputPath
    Path to the .json (preferred) or .csv file written by the matching Export-* script. The
    envelope is validated before anything is changed.

.PARAMETER DataCenterName
    Limit the import to these datacenter names.

.PARAMETER LockerAlias
    Locker alias to use for every vCenter registration, overriding the alias recorded in the
    file.

.PARAMETER IgnoreInvalidCertificate
    Accept an untrusted or self-signed certificate on the target endpoint. Use only in lab
    environments.

.PARAMETER DiffOnly
    Show the planned changes and exit without applying any of them. Use this first, every time.

.EXAMPLE
    PS> ./Import-FleetDataCenterRegistration.ps1 -Server lcm2.example.local -Credential $cred -InputPath ./dcs.json -DiffOnly

    Shows which datacenters and vCenters the target is missing.

.NOTES
    Author        : Sampath
    Product       : VCF Operations fleet management (VCF 9.x)
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
    [Parameter()] [string[]]$DataCenterName,
    [Parameter()] [string]$LockerAlias,
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

$expectedSchema     = 'fleet.datacenter-registration'
$expectedProduct    = 'vcf-operations-fleet-management'
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
    $pair = '{0}:{1}' -f $Credential.UserName, $Credential.GetNetworkCredential().Password
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair))
    $headers = @{ Accept = 'application/json'; Authorization = "Basic $encoded" }
    Write-Verbose "Prepared basic authentication for $Server"

    $desired = Read-ExportFile -Path $InputPath -ExpectedSchema $expectedSchema `
        -ExpectedProduct $expectedProduct -ExpectedVcfVersion $expectedVcfVersion

    if ($DataCenterName) { $desired = @($desired | Where-Object { $_.DataCenter -in $DataCenterName }) }

    $existing = @(Invoke-RestMethod @restCommon -Method Get -Uri "$baseUri/lcm/lcops/api/v2/datacenters" -Headers $headers)
    $existingNames = @($existing.dataCenterName)

    $lockerAliases = @()
    try {
        $lockerResponse = Invoke-RestMethod @restCommon -Method Get -Uri "$baseUri/lcm/locker/api/v2/passwords" -Headers $headers
        $lockerAliases = @($lockerResponse.passwords.alias)
    }
    catch { Write-Verbose 'Could not enumerate locker aliases; alias validation will be skipped.' }

    Write-Verbose ("Input lists {0} row(s); target has {1} datacenter(s)." -f @($desired).Count, $existingNames.Count)

    $plan = @()

    foreach ($group in ($desired | Group-Object DataCenter)) {
        if ($group.Name -notin $existingNames) {
            $plan += [pscustomobject]@{
                Key = 'datacenter:' + $group.Name; Action = 'Create'; ChangedProperty = 'datacenter'
                Kind = 'DataCenter'; DataCenter = $group.Name
                Desired = $group.Group[0]; Current = $null
            }
        }

        foreach ($row in $group.Group) {
            if (-not $row.VCenterHost) { continue }
            $alias = if ($LockerAlias) { $LockerAlias } else { $row.CredentialAlias }

            $plan += [pscustomobject]@{
                Key = 'vcenter:' + $row.VCenterHost; Action = 'Create'; ChangedProperty = 'vcenter'
                Kind = 'VCenter'; DataCenter = $group.Name; VCenterHost = $row.VCenterHost
                Alias = $alias
                AliasPresent = ($lockerAliases.Count -eq 0) -or ($alias -in $lockerAliases)
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
    $datacenterIdByName = @{}
    foreach ($datacenter in @($existing)) { $datacenterIdByName[$datacenter.dataCenterName] = $datacenter.dataCenterVmid }

    foreach ($item in ($actionable | Where-Object Kind -eq 'DataCenter')) {
        if (-not $PSCmdlet.ShouldProcess("datacenter '$($item.DataCenter)'", 'Create')) { continue }

        try {
            $payload = @{ dataCenterName = $item.DataCenter; primaryLocation = $item.Desired.Location } | ConvertTo-Json
            $created = Invoke-RestMethod @restCommon -Method Post -Uri "$baseUri/lcm/lcops/api/v2/datacenters" -Headers $headers -Body $payload
            $datacenterIdByName[$item.DataCenter] = $created.dataCenterVmid
            [pscustomobject]@{ Kind = 'DataCenter'; Name = $item.DataCenter; Status = 'Created' }
        }
        catch {
            Write-Warning ("Could not create datacenter '{0}': {1}" -f $item.DataCenter, $_.Exception.Message)
            [pscustomobject]@{ Kind = 'DataCenter'; Name = $item.DataCenter; Status = 'Failed' }
        }
    }

    foreach ($item in ($actionable | Where-Object Kind -eq 'VCenter')) {
        if (-not $item.AliasPresent) {
            Write-Warning "Locker alias '$($item.Alias)' is not present in the target. Skipping $($item.VCenterHost)."
            [pscustomobject]@{ Kind = 'VCenter'; Name = $item.VCenterHost; Status = 'SkippedMissingAlias' }
            continue
        }

        if (-not $datacenterIdByName.ContainsKey($item.DataCenter)) {
            [pscustomobject]@{ Kind = 'VCenter'; Name = $item.VCenterHost; Status = 'SkippedMissingDataCenter' }
            continue
        }

        if (-not $PSCmdlet.ShouldProcess("vCenter '$($item.VCenterHost)' in '$($item.DataCenter)'", 'Register')) { continue }

        try {
            $payload = @{
                vCenterName = $item.Desired.VCenterName
                vCenterHost = $item.VCenterHost
                vcUsername  = $item.Alias
            } | ConvertTo-Json

            Invoke-RestMethod @restCommon -Method Post `
                -Uri ('{0}/lcm/lcops/api/v2/datacenters/{1}/vcenters' -f $baseUri, $datacenterIdByName[$item.DataCenter]) `
                -Headers $headers -Body $payload | Out-Null

            [pscustomobject]@{ Kind = 'VCenter'; Name = $item.VCenterHost; Status = 'Registered' }
        }
        catch {
            Write-Warning ("Could not register '{0}': {1}" -f $item.VCenterHost, $_.Exception.Message)
            [pscustomobject]@{ Kind = 'VCenter'; Name = $item.VCenterHost; Status = 'Failed' }
        }
    }
}
finally {
    $headers = $null
}
