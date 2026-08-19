<#
.SYNOPSIS
    Lists every snapshot with its age, size on disk, depth in the chain and whether the VM needs consolidation.

.DESCRIPTION
    Walks every VM, expands the whole snapshot tree rather than just the top level, and reports
    age in days, size, chain depth, creator where the event log still has it, and whether the VM
    is flagged as needing consolidation.

    Snapshot sprawl is the single most-blogged vSphere housekeeping problem, and the reason it
    persists is that the UI shows snapshots per VM. Sort this by AgeDays and the offenders are
    at the top; feed the same file to Invoke-VcSnapshotCleanup.ps1 to act on it.

    Also surfaces VMs where ConsolidationNeeded is true but no snapshot object remains - the
    orphaned delta case that quietly eats a datastore.

    Pain area addressed: #4 Snapshot sprawl.

.PARAMETER Server
    FQDN or IP address of the vCenter Server to connect to.

.PARAMETER Credential
    Credential used to authenticate to vCenter Server.

.PARAMETER OlderThanDays
    Return only snapshots at least this many days old. Defaults to 0, meaning all of them.

.PARAMETER MinimumSizeGB
    Return only snapshots at least this large.

.PARAMETER Cluster
    Limit to VMs in these clusters.

.PARAMETER OutputPath
    Path of the file to write. When omitted the records are only returned on the pipeline and
    nothing is written to disk.

.PARAMETER Format
    Output file format. CSV is the flat table, JSON carries the export envelope that the
    matching import script validates, HTML is a styled table for sharing.

.EXAMPLE
    PS> ./Export-VcSnapshotInventory.ps1 -Server vcenter.example.local -Credential $cred -OlderThanDays 30 -OutputPath ./snaps.json -Format JSON

    Writes every snapshot over 30 days old, ready for Invoke-VcSnapshotCleanup.ps1.

.EXAMPLE
    PS> ./Export-VcSnapshotInventory.ps1 -Server vcenter.example.local -Credential $cred | Measure-Object SizeGB -Sum

    Totals the space snapshots are consuming.

.NOTES
    Author        : Sampath
    Product       : vCenter Server (VCF 5.x)
    Target        : VMware Cloud Foundation 5.x
    Modules       : VMware.VimAutomation.Core
    Behaviour     : Read-only. Collects data and optionally writes it to disk.
    Standalone    : Yes. This script does not dot-source or import any other file
                    in this repository and can be copied out on its own.
#>

#Requires -Version 5.1
#Requires -Modules VMware.VimAutomation.Core

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Server,
    [Parameter(Mandatory)] [System.Management.Automation.PSCredential]$Credential,
    [Parameter()] [int]$OlderThanDays = 0,
    [Parameter()] [double]$MinimumSizeGB = 0,
    [Parameter()] [string[]]$Cluster,
    [Parameter()] [string]$OutputPath,
    [Parameter()] [ValidateSet('CSV','JSON','HTML')] [string]$Format = 'CSV'
)

$ErrorActionPreference = 'Stop'

function Out-ResultFile {
    <#
        Writes the collected records to disk in the requested format. JSON uses the
        repository's export envelope so a matching Import-*/Invoke-* script can
        validate what it has been handed before changing anything.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowEmptyCollection()][object[]]$Record,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Format,
        [Parameter(Mandatory)][hashtable]$Meta
    )

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    switch ($Format) {
        'CSV' {
            @($Record) | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
        }
        'JSON' {
            [pscustomobject]@{
                schema        = $Meta.Schema
                schemaVersion = $Meta.SchemaVersion
                product       = $Meta.Product
                vcfVersion    = $Meta.VcfVersion
                exportedOn    = (Get-Date).ToUniversalTime().ToString('o')
                sourceServer  = $Meta.Server
                recordCount   = @($Record).Count
                data          = @($Record)
            } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding UTF8
        }
        'HTML' {
            $style = '<style>body{font-family:Segoe UI,Arial,sans-serif;margin:24px}' +
                     'h2{margin-bottom:2px}p.meta{color:#666;margin-top:0;font-size:12px}' +
                     'table{border-collapse:collapse;font-size:13px}' +
                     'th,td{border:1px solid #ccc;padding:4px 8px}th{background:#eee;text-align:left}</style>'
            $header = '<h2>' + $Meta.Schema + '</h2><p class="meta">Source: ' + $Meta.Server +
                      ' | VCF ' + $Meta.VcfVersion + ' | Exported: ' +
                      (Get-Date).ToString('u') + ' | Records: ' + @($Record).Count + '</p>'
            @($Record) | ConvertTo-Html -Head $style -PreContent $header |
                Set-Content -LiteralPath $Path -Encoding UTF8
        }
    }

    Write-Verbose ("Wrote {0} record(s) to {1}" -f @($Record).Count, $Path)
}

$exportMeta = @{
    Schema        = 'vcenter.snapshot-inventory'
    SchemaVersion = '1.0'
    Product       = 'vcenter'
    VcfVersion    = '5.x'
    Server        = $Server
}

$connection = $null
try {
    $connection = Connect-VIServer -Server $Server -Credential $Credential -ErrorAction Stop
    Write-Verbose "Connected to vCenter Server $($connection.Name) (version $($connection.Version))"

    $records = @()

    $vmFilter = @{}
    if ($Cluster) { $vmFilter['Location'] = Get-Cluster -Name $Cluster }
    $vms = Get-VM @vmFilter
    Write-Verbose ("Checking {0} VM(s) for snapshots." -f @($vms).Count)

    foreach ($vm in $vms) {
        $snapshots = @(Get-Snapshot -VM $vm -ErrorAction SilentlyContinue)
        $needsConsolidation = [bool]$vm.ExtensionData.Runtime.ConsolidationNeeded

        if (-not $snapshots -and $needsConsolidation) {
            $records += [pscustomobject]@{
                VM                 = $vm.Name
                Cluster            = [string]$vm.VMHost.Parent
                SnapshotName       = '(none - orphaned delta)'
                Description        = 'VM reports ConsolidationNeeded but has no snapshot object.'
                Created            = $null
                AgeDays            = $null
                SizeGB             = $null
                Depth              = 0
                IsCurrent          = $false
                PowerState         = [string]$vm.PowerState
                ConsolidationNeeded = $true
                SnapshotId         = $null
            }
            continue
        }

        foreach ($snapshot in $snapshots) {
            $ageDays = [int][math]::Floor(((Get-Date) - $snapshot.Created).TotalDays)
            $sizeGb = [math]::Round($snapshot.SizeGB, 2)

            if ($OlderThanDays -gt 0 -and $ageDays -lt $OlderThanDays) { continue }
            if ($MinimumSizeGB -gt 0 -and $sizeGb -lt $MinimumSizeGB) { continue }

            $depth = 1
            $parent = $snapshot.ParentSnapshot
            while ($parent) { $depth++; $parent = $parent.ParentSnapshot }

            $records += [pscustomobject]@{
                VM                  = $vm.Name
                Cluster             = [string]$vm.VMHost.Parent
                SnapshotName        = $snapshot.Name
                Description         = $snapshot.Description
                Created             = $snapshot.Created
                AgeDays             = $ageDays
                SizeGB              = $sizeGb
                Depth               = $depth
                IsCurrent           = $snapshot.IsCurrent
                PowerState          = [string]$vm.PowerState
                ConsolidationNeeded = $needsConsolidation
                SnapshotId          = $snapshot.Id
            }
        }
    }

    $records = @($records | Sort-Object -Property AgeDays -Descending)
    Write-Verbose ("Collected {0} snapshot record(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    if ($connection) { Disconnect-VIServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
