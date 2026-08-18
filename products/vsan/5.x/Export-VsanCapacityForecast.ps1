<#
.SYNOPSIS
    Reports vSAN capacity, usage breakdown, slack space and a straight-line estimate of how long the free space lasts.

.DESCRIPTION
    Per cluster: raw and usable capacity, what is consumed by VM objects, what deduplication and
    compression are saving, the reserved slack space, and free capacity - then a runway estimate
    from the VM growth you supply, because vSAN itself will not forecast for you.

    The runway is a straight-line estimate, not a model. It exists so that 'we have 18TB free'
    becomes 'that is about seven months at the rate we added VMs last quarter', which is the
    form a capacity conversation actually needs.

    Pain area addressed: #11 vSAN health, capacity, policy compliance.

.PARAMETER Server
    FQDN or IP address of the vCenter Server to connect to.

.PARAMETER Credential
    Credential used to authenticate to vCenter Server.

.PARAMETER Cluster
    Limit to these clusters.

.PARAMETER MonthlyGrowthGB
    Expected consumed-capacity growth per month, in GB, used for the runway estimate. Omit to
    skip the estimate.

.PARAMETER SlackPercent
    Slack space to keep in reserve when calculating usable free capacity. Defaults to 25,
    matching vSAN guidance.

.PARAMETER OutputPath
    Path of the file to write. When omitted the records are only returned on the pipeline and
    nothing is written to disk.

.PARAMETER Format
    Output file format. CSV is the flat table, JSON carries the export envelope that the
    matching import script validates, HTML is a styled table for sharing.

.EXAMPLE
    PS> ./Export-VsanCapacityForecast.ps1 -Server vcenter.example.local -Credential $cred -MonthlyGrowthGB 800

    Reports capacity for every cluster with a runway estimate at 800 GB per month of growth.

.NOTES
    Author        : Sampath
    Product       : vSAN (VCF 5.x)
    Target        : VMware Cloud Foundation 5.x
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
    [Parameter()] [double]$MonthlyGrowthGB = 0,
    [Parameter()] [int]$SlackPercent = 25,
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
    Schema        = 'vsan.capacity'
    SchemaVersion = '1.0'
    Product       = 'vsan'
    VcfVersion    = '5.x'
    Server        = $Server
}

$connection = $null
try {
    $connection = Connect-VIServer -Server $Server -Credential $Credential -ErrorAction Stop
    Write-Verbose "Connected to vCenter Server $($connection.Name) (version $($connection.Version))"

    $records = @()

    $clusters = Get-Cluster
    if ($Cluster) { $clusters = @($clusters | Where-Object { $_.Name -in $Cluster }) }
    $clusters = @($clusters | Where-Object { $_.VsanEnabled })
    Write-Verbose ("Found {0} vSAN-enabled cluster(s)." -f @($clusters).Count)

    foreach ($vsanCluster in $clusters) {
        $usage = $null
        try { $usage = Get-VsanSpaceUsage -Cluster $vsanCluster -ErrorAction Stop }
        catch {
            Write-Warning ("Could not read space usage on '{0}': {1}" -f $vsanCluster.Name, $_.Exception.Message)
            continue
        }

        $config = Get-VsanClusterConfiguration -Cluster $vsanCluster -ErrorAction SilentlyContinue

        $capacityGb = [double]$usage.CapacityGB
        $usedGb = [double]$usage.UsedCapacityGB
        $freeGb = [double]$usage.FreeSpaceGB
        $slackGb = [math]::Round($capacityGb * ($SlackPercent / 100.0), 1)
        $usableFreeGb = [math]::Round($freeGb - $slackGb, 1)

        $runwayMonths = $null
        if ($MonthlyGrowthGB -gt 0) {
            $runwayMonths = [math]::Round($usableFreeGb / $MonthlyGrowthGB, 1)
        }

        $records += [pscustomobject]@{
            Cluster              = $vsanCluster.Name
            Hosts                = @(Get-VMHost -Location $vsanCluster).Count
            CapacityGB           = [math]::Round($capacityGb, 1)
            UsedGB               = [math]::Round($usedGb, 1)
            FreeGB               = [math]::Round($freeGb, 1)
            UsedPercent          = if ($capacityGb -gt 0) { [math]::Round(($usedGb / $capacityGb) * 100, 1) } else { $null }
            SlackReserveGB       = $slackGb
            UsableFreeGB         = $usableFreeGb
            VmObjectGB           = [math]::Round([double]$usage.VmSpaceGB, 1)
            DedupCompressionOn   = if ($config) { $config.SpaceEfficiencyEnabled } else { $null }
            EncryptionOn         = if ($config) { $config.EncryptionEnabled } else { $null }
            MonthlyGrowthGB      = if ($MonthlyGrowthGB -gt 0) { $MonthlyGrowthGB } else { $null }
            RunwayMonths         = $runwayMonths
            Verdict              = if ($null -eq $runwayMonths) { 'NoForecast' }
                                   elseif ($runwayMonths -lt 3) { 'ActNow' }
                                   elseif ($runwayMonths -lt 6) { 'PlanSoon' }
                                   else { 'Comfortable' }
        }
    }

    $records = @($records | Sort-Object UsedPercent -Descending)
    Write-Verbose ("Collected capacity for {0} cluster(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    if ($connection) { Disconnect-VIServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
