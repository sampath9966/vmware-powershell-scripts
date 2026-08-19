<#
.SYNOPSIS
    Creates the segments described in a topology export that do not exist in the target NSX.

.DESCRIPTION
    Compares segments in the file against the target and creates the missing ones with their
    subnets, VLAN ids and transport zone, attaching them to the tier-1 named in the file when
    one with that name exists here.

    Gateways are not created - tier-0 uplinks and edge cluster placement are site specific. A
    segment whose tier-1 is missing is created disconnected and reported as such, so the gap is
    visible rather than silent.

    Pain area addressed: #16 Config portability between environments.

.PARAMETER Server
    FQDN or IP address of the NSX Manager to connect to.

.PARAMETER Credential
    Credential used to authenticate to NSX Manager.

.PARAMETER InputPath
    Path to the .json (preferred) or .csv file written by the matching Export-* script. The
    envelope is validated before anything is changed.

.PARAMETER SegmentName
    Limit the import to these segment names.

.PARAMETER TransportZone
    Override the transport zone from the file with this one. Usually needed, since zone ids
    differ per site.

.PARAMETER DiffOnly
    Show the planned changes and exit without applying any of them. Use this first, every time.

.EXAMPLE
    PS> ./Import-NsxSegment.ps1 -Server nsx-dr.example.local -Credential $cred -InputPath ./segments.json -DiffOnly

    Shows which segments are missing in the target NSX.

.NOTES
    Author        : Sampath
    Product       : NSX (including vDefend) (VCF 9.x)
    Target        : VMware Cloud Foundation 9.x
    Modules       : VMware.VimAutomation.Nsxt
    Behaviour     : Changes the target. Supports -WhatIf, -Confirm and -DiffOnly.
    Standalone    : Yes. This script does not dot-source or import any other file
                    in this repository and can be copied out on its own.
#>

#Requires -Version 5.1
#Requires -Modules VMware.VimAutomation.Nsxt

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Server,
    [Parameter(Mandatory)] [System.Management.Automation.PSCredential]$Credential,
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$InputPath,
    [Parameter()] [string[]]$SegmentName,
    [Parameter()] [string]$TransportZone,
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

$expectedSchema     = 'nsx.segment-topology'
$expectedProduct    = 'nsx'
$expectedVcfVersion = '9.x'

$connection = $null
try {
    $connection = Connect-NsxtServer -Server $Server -Credential $Credential -ErrorAction Stop
    Write-Verbose "Connected to NSX Manager $($connection.Name)"
    # Scope every call in this script to the connection opened above. Without this,
    # PowerCLI cmdlets act on every connected server, which silently mixes inventories
    # when more than one is connected. The hashtable is cloned first because indexing
    # the inherited one would change the caller's session defaults too.
    $PSDefaultParameterValues = $PSDefaultParameterValues.Clone()
    $PSDefaultParameterValues['*:Server'] = $connection

    $desired = Read-ExportFile -Path $InputPath -ExpectedSchema $expectedSchema `
        -ExpectedProduct $expectedProduct -ExpectedVcfVersion $expectedVcfVersion

    if ($SegmentName) { $desired = @($desired | Where-Object { $_.Segment -in $SegmentName }) }

    $segmentService = Get-NsxtPolicyService -Name 'com.vmware.nsx_policy.infra.segments'
    $tier1Service = Get-NsxtPolicyService -Name 'com.vmware.nsx_policy.infra.tier_1s'
    $zoneService = Get-NsxtPolicyService -Name 'com.vmware.nsx_policy.infra.sites.enforcement_points.transport_zones'

    $tier1PathByName = @{}
    foreach ($tier1 in @($tier1Service.list().results)) { $tier1PathByName[$tier1.display_name] = $tier1.path }

    $zonePathByName = @{}
    try {
        foreach ($zone in @($zoneService.list('default', 'default').results)) { $zonePathByName[$zone.display_name] = $zone.path }
    }
    catch { Write-Verbose 'Could not enumerate transport zones; -TransportZone will need a full path.' }

    $current = foreach ($segment in @($segmentService.list().results)) {
        [pscustomobject]@{ Segment = $segment.display_name; Subnets = (@($segment.subnets).gateway_address -join '; ') }
    }

    Write-Verbose ("Input lists {0} segment(s); target has {1}." -f @($desired).Count, @($current).Count)

    $plan = Compare-DesiredState -Current @($current) -Desired @($desired) `
        -KeyProperty 'Segment' -CompareProperty @('Subnets')

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
    foreach ($item in ($actionable | Where-Object { $_.Action -eq 'Create' })) {
        $row = $item.Desired

        if (-not $PSCmdlet.ShouldProcess("segment '$($item.Key)'", 'Create')) { continue }

        try {
            $spec = $segmentService.Help.patch.segment.Create()
            $spec.display_name = $row.Segment

            if ($row.VlanIds) { $spec.vlan_ids = @($row.VlanIds -split ',' | Where-Object { $_ }) }

            if ($row.Subnets) {
                $subnetList = @()
                foreach ($gateway in @($row.Subnets -split '\s*;\s*' | Where-Object { $_ })) {
                    $subnet = $segmentService.Help.patch.segment.subnets.Element.Create()
                    $subnet.gateway_address = $gateway
                    $subnetList += $subnet
                }
                $spec.subnets = $subnetList
            }

            $zoneName = if ($TransportZone) { $TransportZone } else { $row.TransportZone }
            if ($zoneName) {
                $spec.transport_zone_path = if ($zonePathByName.ContainsKey($zoneName)) { $zonePathByName[$zoneName] } else { $zoneName }
            }

            $connected = $false
            if ($row.Tier1 -and $tier1PathByName.ContainsKey($row.Tier1)) {
                $spec.connectivity_path = $tier1PathByName[$row.Tier1]
                $connected = $true
            }
            elseif ($row.Tier1) {
                Write-Warning "Tier-1 '$($row.Tier1)' does not exist here. Creating '$($item.Key)' disconnected."
            }

            $segmentId = if ($row.SegmentId) { $row.SegmentId } else { $row.Segment -replace '[^A-Za-z0-9_-]', '-' }
            $segmentService.patch($segmentId, $spec) | Out-Null

            [pscustomobject]@{ Segment = $item.Key; Connected = $connected; Status = 'Created' }
        }
        catch {
            Write-Warning ("Could not create segment '{0}': {1}" -f $item.Key, $_.Exception.Message)
            [pscustomobject]@{ Segment = $item.Key; Connected = $false; Status = 'Failed' }
        }
    }
}
finally {
    if ($connection) { Disconnect-NsxtServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
