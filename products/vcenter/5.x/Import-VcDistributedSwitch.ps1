<#
.SYNOPSIS
    Creates the distributed port groups described in an export on an existing switch, matching VLAN and teaming.

.DESCRIPTION
    Compares the port groups in the file against what the target switch already has and creates
    the missing ones with the same VLAN configuration and port count. Port groups that exist
    with a different VLAN come back as Update so the drift is visible.

    The switch itself is not created - uplink and host membership are environment specific and
    creating them blind causes more harm than it saves. Point -TargetVDSwitch at a switch that
    already exists.

    Pain area addressed: #16 Config portability between environments.

.PARAMETER Server
    FQDN or IP address of the vCenter Server to connect to.

.PARAMETER Credential
    Credential used to authenticate to vCenter Server.

.PARAMETER InputPath
    Path to the .json (preferred) or .csv file written by the matching Export-* script. The
    envelope is validated before anything is changed.

.PARAMETER TargetVDSwitch
    Name of the existing distributed switch in this vCenter to create the port groups on.

.PARAMETER SourceVDSwitch
    Only import port groups that came from this switch in the export. Useful when the file holds
    several.

.PARAMETER UpdateExisting
    Also correct the VLAN of port groups that exist but differ from the file.

.PARAMETER DiffOnly
    Show the planned changes and exit without applying any of them. Use this first, every time.

.EXAMPLE
    PS> ./Import-VcDistributedSwitch.ps1 -Server vcenter2.example.local -Credential $cred -InputPath ./vds.json -TargetVDSwitch dvs-dr -DiffOnly

    Shows which port groups are missing from the target switch.

.NOTES
    Author        : Sampath
    Product       : vCenter Server (VCF 5.x)
    Target        : VMware Cloud Foundation 5.x
    Modules       : VMware.VimAutomation.Core, VMware.VimAutomation.Vds
    Behaviour     : Changes the target. Supports -WhatIf, -Confirm and -DiffOnly.
    Standalone    : Yes. This script does not dot-source or import any other file
                    in this repository and can be copied out on its own.
#>

#Requires -Version 5.1
#Requires -Modules VMware.VimAutomation.Core
#Requires -Modules VMware.VimAutomation.Vds

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Server,
    [Parameter(Mandatory)] [System.Management.Automation.PSCredential]$Credential,
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$InputPath,
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$TargetVDSwitch,
    [Parameter()] [string]$SourceVDSwitch,
    [Parameter()] [switch]$UpdateExisting,
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

$expectedSchema     = 'vcenter.distributed-switch'
$expectedProduct    = 'vcenter'
$expectedVcfVersion = '5.x'

$connection = $null
try {
    $connection = Connect-VIServer -Server $Server -Credential $Credential -ErrorAction Stop
    Write-Verbose "Connected to vCenter Server $($connection.Name) (version $($connection.Version))"
    if (@($DefaultVIServers).Count -gt 1) {
        Write-Warning (("{0} vCenter connections are open in this session. PowerCLI cmdlets act on " +
            "every connected server unless they are scoped, which silently mixes inventories. " +
            "This script scopes its own calls to '{1}'.") -f @($DefaultVIServers).Count, $connection.Name)
    }

    $desired = Read-ExportFile -Path $InputPath -ExpectedSchema $expectedSchema `
        -ExpectedProduct $expectedProduct -ExpectedVcfVersion $expectedVcfVersion

    $desired = @($desired | Where-Object { $_.Kind -eq 'PortGroup' })
    if ($SourceVDSwitch) { $desired = @($desired | Where-Object { $_.VDSwitch -eq $SourceVDSwitch }) }

    $vds = Get-VDSwitch -Name $TargetVDSwitch -ErrorAction Stop
    Write-Verbose ("Target switch '{0}' currently has {1} port group(s); input describes {2}." -f `
        $vds.Name, @(Get-VDPortgroup -VDSwitch $vds).Count, @($desired).Count)

    $current = foreach ($portGroup in (Get-VDPortgroup -VDSwitch $vds)) {
        [pscustomobject]@{
            PortGroup = $portGroup.Name
            VlanId    = [string]$portGroup.ExtensionData.Config.DefaultPortConfig.Vlan.VlanId
            NumPorts  = $portGroup.NumPorts
        }
    }

    $plan = Compare-DesiredState -Current @($current) -Desired @($desired) `
        -KeyProperty 'PortGroup' -CompareProperty @('VlanId')

    if (-not $UpdateExisting) {
        $plan = @($plan | ForEach-Object {
            if ($_.Action -eq 'Update') { $_.Action = 'Match' }
            $_
        })
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

        if ($item.Action -eq 'Create') {
            if (-not $PSCmdlet.ShouldProcess("port group '$($item.Key)' on '$TargetVDSwitch'", 'Create')) { continue }

            $newParams = @{
                Name       = $item.Key
                VDSwitch   = $vds
                Confirm    = $false
                ErrorAction = 'Stop'
            }
            if ($row.NumPorts) { $newParams['NumPorts'] = [int]$row.NumPorts }
            if ($row.VlanType -eq 'Trunk') {
                $newParams['VlanTrunkRange'] = $row.VlanId
            }
            elseif ($row.VlanId -and $row.VlanId -ne '0') {
                $newParams['VlanId'] = [int]$row.VlanId
            }

            try {
                New-VDPortgroup @newParams | Out-Null
                [pscustomobject]@{ PortGroup = $item.Key; Action = 'Create'; Status = 'Created' }
            }
            catch {
                Write-Warning ("Could not create '{0}': {1}" -f $item.Key, $_.Exception.Message)
                [pscustomobject]@{ PortGroup = $item.Key; Action = 'Create'; Status = 'Failed' }
            }
        }
        else {
            if (-not $PSCmdlet.ShouldProcess("port group '$($item.Key)'", "Set VLAN to $($row.VlanId)")) { continue }

            Get-VDPortgroup -VDSwitch $vds -Name $item.Key |
                Set-VDVlanConfiguration -VlanId ([int]$row.VlanId) -Confirm:$false | Out-Null
            [pscustomobject]@{ PortGroup = $item.Key; Action = 'Update'; Status = 'VlanUpdated' }
        }
    }
}
finally {
    if ($connection) { Disconnect-VIServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
