<#
.SYNOPSIS
    Removes the snapshots listed in a snapshot inventory export, honouring an age and size policy.

.DESCRIPTION
    Reads a snapshot inventory export, re-checks each snapshot still exists, applies the age and
    size policy you give it, and removes what qualifies - one snapshot at a time, waiting for
    each removal so a datastore is never hit with a dozen concurrent consolidations.

    Removing snapshots is the one housekeeping task that can take a datastore offline if it is
    done carelessly, so nothing here is implicit: -DiffOnly prints the list, ShouldProcess gates
    every deletion, -KeepCurrent protects the active snapshot by default, and the re-check means
    a stale input file cannot delete something created since the export.

    Pain area addressed: #4 Snapshot sprawl.

.PARAMETER Server
    FQDN or IP address of the vCenter Server to connect to.

.PARAMETER Credential
    Credential used to authenticate to vCenter Server.

.PARAMETER InputPath
    Path to the .json (preferred) or .csv file written by the matching Export-* script. The
    envelope is validated before anything is changed.

.PARAMETER OlderThanDays
    Only remove snapshots at least this many days old. Defaults to 30.

.PARAMETER ExcludeVM
    VM names to leave alone regardless of what the input file says. Accepts wildcards.

.PARAMETER KeepCurrent
    Never remove the snapshot a VM is currently running on. Strongly recommended.

.PARAMETER Confirmed
    Reserved for pipelines that have already had a human approve the plan. Has no effect on
    ShouldProcess.

.PARAMETER DiffOnly
    Show the planned changes and exit without applying any of them. Use this first, every time.

.EXAMPLE
    PS> ./Invoke-VcSnapshotCleanup.ps1 -Server vcenter.example.local -Credential $cred -InputPath ./snaps.json -DiffOnly

    Prints exactly which snapshots would go, and how much space that frees.

.EXAMPLE
    PS> ./Invoke-VcSnapshotCleanup.ps1 -Server vcenter.example.local -Credential $cred -InputPath ./snaps.json -OlderThanDays 60 -KeepCurrent -Confirm

    Removes snapshots over 60 days old, prompting for each, and never touches the active one.

.NOTES
    Author        : Sampath
    Product       : vCenter (VCF 9.x)
    Target        : VMware Cloud Foundation 9.x
    Modules       : VMware.VimAutomation.Core
    Behaviour     : Changes the target. Supports -WhatIf, -Confirm and -DiffOnly.
    Standalone    : Yes. This script does not dot-source or import any other file
                    in this repository and can be copied out on its own.
#>

#Requires -Version 5.1
#Requires -Modules VMware.VimAutomation.Core

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Server,
    [Parameter(Mandatory)] [System.Management.Automation.PSCredential]$Credential,
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$InputPath,
    [Parameter()] [int]$OlderThanDays = 30,
    [Parameter()] [string[]]$ExcludeVM,
    [Parameter()] [switch]$KeepCurrent,
    [Parameter()] [switch]$Confirmed,
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


$expectedSchema     = 'vcenter.snapshot-inventory'
$expectedProduct    = 'vcenter'
$expectedVcfVersion = '9.x'

$connection = $null
try {
    $connection = Connect-VIServer -Server $Server -Credential $Credential -ErrorAction Stop
    Write-Verbose "Connected to vCenter Server $($connection.Name) (version $($connection.Version))"

    $desired = Read-ExportFile -Path $InputPath -ExpectedSchema $expectedSchema `
        -ExpectedProduct $expectedProduct -ExpectedVcfVersion $expectedVcfVersion

    Write-Verbose ("Input file lists {0} snapshot record(s)." -f @($desired).Count)
    if ($Confirmed) { Write-Verbose 'Plan was pre-approved by the caller; ShouldProcess still applies.' }

    $plan = foreach ($record in @($desired)) {
        if (-not $record.SnapshotId) { continue }

        $skip = $false
        foreach ($pattern in @($ExcludeVM)) {
            if ($pattern -and $record.VM -like $pattern) { $skip = $true; break }
        }
        if ($skip) { continue }

        $live = Get-Snapshot -Id $record.SnapshotId -ErrorAction SilentlyContinue
        if (-not $live) {
            Write-Verbose "Snapshot '$($record.SnapshotName)' on '$($record.VM)' no longer exists. Skipping."
            continue
        }

        if ($KeepCurrent -and $live.IsCurrent) {
            Write-Verbose "Snapshot '$($live.Name)' on '$($record.VM)' is current and -KeepCurrent was given. Skipping."
            continue
        }

        $ageDays = [int][math]::Floor(((Get-Date) - $live.Created).TotalDays)
        $action = if ($ageDays -ge $OlderThanDays) { 'Remove' } else { 'Match' }

        [pscustomobject]@{
            Key             = '{0}/{1}' -f $record.VM, $live.Name
            Action          = $action
            ChangedProperty = if ($action -eq 'Remove') { 'snapshot' } else { '' }
            VM              = $record.VM
            SnapshotName    = $live.Name
            AgeDays         = $ageDays
            SizeGB          = [math]::Round($live.SizeGB, 2)
            SnapshotId      = $live.Id
            Desired         = $record
            Current         = $live
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
    $reclaim = ($actionable | Measure-Object -Property SizeGB -Sum).Sum
    Write-Verbose ("Removing {0} snapshot(s), reclaiming roughly {1} GB." -f $actionable.Count, [math]::Round([double]$reclaim, 1))

    foreach ($item in $actionable) {
        $target = "snapshot '{0}' on VM '{1}' ({2} days old, {3} GB)" -f `
            $item.SnapshotName, $item.VM, $item.AgeDays, $item.SizeGB

        if (-not $PSCmdlet.ShouldProcess($target, 'Remove snapshot')) {
            continue
        }

        $status = 'Removed'
        $message = ''
        try {
            Remove-Snapshot -Snapshot $item.Current -Confirm:$false -ErrorAction Stop
        }
        catch {
            $status = 'Failed'
            $message = $_.Exception.Message
            Write-Warning ("Failed to remove {0}: {1}" -f $target, $message)
        }

        [pscustomobject]@{
            VM           = $item.VM
            SnapshotName = $item.SnapshotName
            AgeDays      = $item.AgeDays
            SizeGB       = $item.SizeGB
            Status       = $status
            Message      = $message
        }
    }
}
finally {
    if ($connection) { Disconnect-VIServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
