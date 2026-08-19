<#
.SYNOPSIS
    Exports vSAN cluster settings, disk group or storage pool layout, and stretched cluster witness detail.

.DESCRIPTION
    Per cluster: whether deduplication and compression, encryption and performance service are
    on, the space efficiency mode, the disk claim mode, plus a row per disk group or storage
    pool with its cache and capacity devices - and the witness host and preferred fault domain
    for stretched clusters.

    This is the record you want before you change anything, and the one nobody takes. It also
    makes 'is cluster B configured the same as cluster A' a diff rather than a memory test.

    Pain area addressed: #16 Config portability between environments; #11 vSAN health, capacity,
    policy compliance.

.PARAMETER Server
    FQDN or IP address of the vCenter Server to connect to.

.PARAMETER Credential
    Credential used to authenticate to vCenter Server.

.PARAMETER Cluster
    Limit to these clusters.

.PARAMETER IncludeDiskDetail
    Add one row per physical disk with its capacity and role.

.PARAMETER OutputPath
    Path of the file to write. When omitted the records are only returned on the pipeline and
    nothing is written to disk.

.PARAMETER Format
    Output file format. CSV is the flat table, JSON carries the export envelope that the
    matching import script validates, HTML is a styled table for sharing.

.EXAMPLE
    PS> ./Export-VsanClusterConfig.ps1 -Server vcenter.example.local -Credential $cred -IncludeDiskDetail -OutputPath ./vsancfg.json -Format JSON

    Captures the full configuration including physical disk layout.

.NOTES
    Author        : Sampath
    Product       : vSAN (ESA and OSA) (VCF 9.x)
    Target        : VMware Cloud Foundation 9.x
    Modules       : VMware.VimAutomation.Core, VMware.VimAutomation.Storage
    Behaviour     : Read-only. Collects data and optionally writes it to disk.
    Standalone    : Yes. This script does not dot-source or import any other file
                    in this repository and can be copied out on its own.
#>

#Requires -Version 5.1
#Requires -Modules VMware.VimAutomation.Core
#Requires -Modules VMware.VimAutomation.Storage

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Server,
    [Parameter(Mandatory)] [System.Management.Automation.PSCredential]$Credential,
    [Parameter()] [string[]]$Cluster,
    [Parameter()] [switch]$IncludeDiskDetail,
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
    Schema        = 'vsan.cluster-config'
    SchemaVersion = '1.0'
    Product       = 'vsan'
    VcfVersion    = '9.x'
    Server        = $Server
}

$connection = $null
try {
    $connection = Connect-VIServer -Server $Server -Credential $Credential -ErrorAction Stop
    Write-Verbose "Connected to vCenter Server $($connection.Name) (version $($connection.Version))"
    if (@($DefaultVIServers).Count -gt 1) {
        Write-Warning (("{0} vCenter connections are open in this session. PowerCLI cmdlets act on " +
            "every connected server unless they are scoped, which silently mixes inventories. " +
            "This script scopes its own calls to '{1}'.") -f @($DefaultVIServers).Count, $connection.Name)
    }
    # Scope every call in this script to the connection opened above. Without this,
    # PowerCLI cmdlets act on every connected server, which silently mixes inventories
    # when more than one is connected. The hashtable is cloned first because indexing
    # the inherited one would change the caller's session defaults too.
    $PSDefaultParameterValues = $PSDefaultParameterValues.Clone()
    $PSDefaultParameterValues['*:Server'] = $connection

    $records = @()

    $clusters = Get-Cluster
    if ($Cluster) { $clusters = @($clusters | Where-Object { $_.Name -in $Cluster }) }
    $clusters = @($clusters | Where-Object { $_.VsanEnabled })
    Write-Verbose ("Found {0} vSAN-enabled cluster(s)." -f @($clusters).Count)

    foreach ($vsanCluster in $clusters) {
        $config = Get-VsanClusterConfiguration -Cluster $vsanCluster -ErrorAction SilentlyContinue

        $records += [pscustomobject]@{
            Kind                 = 'Cluster'
            Cluster              = $vsanCluster.Name
            VMHost               = ''
            DiskGroup            = ''
            Device               = ''
            DeviceRole           = ''
            CapacityGB           = $null
            VsanEnabled          = $vsanCluster.VsanEnabled
            SpaceEfficiency      = if ($config) { $config.SpaceEfficiencyEnabled } else { $null }
            EncryptionEnabled    = if ($config) { $config.EncryptionEnabled } else { $null }
            PerformanceService   = if ($config) { $config.PerformanceServiceEnabled } else { $null }
            DiskClaimMode        = if ($config) { [string]$config.VsanDiskClaimMode } else { '' }
            StretchedEnabled     = if ($config) { $config.StretchedClusterEnabled } else { $null }
            WitnessHost          = if ($config) { [string]$config.WitnessHost } else { '' }
            PreferredFaultDomain = if ($config) { [string]$config.PreferredFaultDomain } else { '' }
        }

        if (-not $IncludeDiskDetail) { continue }

        foreach ($vmHost in (Get-VMHost -Location $vsanCluster)) {
            foreach ($diskGroup in (Get-VsanDiskGroup -VMHost $vmHost -ErrorAction SilentlyContinue)) {
                foreach ($disk in (Get-VsanDisk -VsanDiskGroup $diskGroup -ErrorAction SilentlyContinue)) {
                    $records += [pscustomobject]@{
                        Kind                 = 'Disk'
                        Cluster              = $vsanCluster.Name
                        VMHost               = $vmHost.Name
                        DiskGroup            = $diskGroup.Name
                        Device               = $disk.CanonicalName
                        DeviceRole           = if ($disk.IsCacheDisk) { 'Cache' } else { 'Capacity' }
                        CapacityGB           = [math]::Round([double]$disk.CapacityGB, 1)
                        VsanEnabled          = $true
                        SpaceEfficiency      = $null
                        EncryptionEnabled    = $null
                        PerformanceService   = $null
                        DiskClaimMode        = ''
                        StretchedEnabled     = $null
                        WitnessHost          = ''
                        PreferredFaultDomain = ''
                    }
                }
            }
        }
    }

    $records = @($records | Sort-Object Cluster, Kind, VMHost, DiskGroup, Device)
    Write-Verbose ("Collected {0} configuration row(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    if ($connection) { Disconnect-VIServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
