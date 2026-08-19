<#
.SYNOPSIS
    Pulls a named metric series for many resources at once, into a single long-format table.

.DESCRIPTION
    Takes a resource kind, a list of metric keys and a time window, and returns one row per
    resource, metric and sample - the long format that pivots cleanly in a spreadsheet or feeds
    straight into anything that expects tidy data.

    Getting historical numbers out of Operations for capacity work normally means either a view
    that rounds everything or clicking through the metric chart per object. This is the bulk
    version, and it is the script most likely to be wrapped in a scheduled job.

    Pain area addressed: #14 Rightsizing and idle workloads.

.PARAMETER Server
    FQDN or IP address of the VCF Operations (Aria Operations) analytics node.

.PARAMETER Credential
    Credential used to authenticate to VCF Operations.

.PARAMETER ResourceKind
    Resource kind to pull, for example VirtualMachine, HostSystem or ClusterComputeResource.

.PARAMETER MetricKey
    Metric keys to pull, for example 'cpu|demandmhz' or 'mem|consumed_average'.

.PARAMETER Days
    How many days of history to pull. Defaults to 7.

.PARAMETER Name
    Limit to these resource names.

.PARAMETER OutputPath
    Path of the file to write. When omitted the records are only returned on the pipeline and
    nothing is written to disk.

.PARAMETER Format
    Output file format. CSV is the flat table, JSON carries the export envelope that the
    matching import script validates, HTML is a styled table for sharing.

.EXAMPLE
    PS> ./Export-OpsMetricSeries.ps1 -Server ops.example.local -Credential $cred -MetricKey 'cpu|demandmhz','mem|consumed_average' -Days 30 -OutputPath ./metrics.csv

    Pulls a month of CPU and memory history for every VM.

.NOTES
    Author        : Sampath
    Product       : Aria Operations (VCF 5.x)
    Target        : VMware Cloud Foundation 5.x
    Modules       : VMware.VimAutomation.vROps
    Behaviour     : Read-only. Collects data and optionally writes it to disk.
    Standalone    : Yes. This script does not dot-source or import any other file
                    in this repository and can be copied out on its own.
#>

#Requires -Version 5.1
#Requires -Modules VMware.VimAutomation.vROps

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Server,
    [Parameter(Mandatory)] [System.Management.Automation.PSCredential]$Credential,
    [Parameter()] [string]$ResourceKind = 'VirtualMachine',
    [Parameter(Mandatory)] [string[]]$MetricKey,
    [Parameter()] [int]$Days = 7,
    [Parameter()] [string[]]$Name,
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
    Schema        = 'vcf-operations.metric-series'
    SchemaVersion = '1.0'
    Product       = 'vcf-operations'
    VcfVersion    = '5.x'
    Server        = $Server
}

$connection = $null
try {
    $connection = Connect-OMServer -Server $Server -Credential $Credential -ErrorAction Stop
    Write-Verbose "Connected to VCF Operations $($connection.Name)"
    # Scope every call in this script to the connection opened above. Without this,
    # PowerCLI cmdlets act on every connected server, which silently mixes inventories
    # when more than one is connected. The hashtable is cloned first because indexing
    # the inherited one would change the caller's session defaults too.
    $PSDefaultParameterValues = $PSDefaultParameterValues.Clone()
    $PSDefaultParameterValues['*:Server'] = $connection

    $records = @()

    $resourceParams = @{ ResourceKind = $ResourceKind }
    if ($Name) { $resourceParams['Name'] = $Name }
    $resources = Get-OMResource @resourceParams
    Write-Verbose ("Pulling {0} metric(s) for {1} resource(s) over {2} day(s)." -f @($MetricKey).Count, @($resources).Count, $Days)

    $from = (Get-Date).AddDays(-$Days)

    foreach ($resource in $resources) {
        foreach ($key in $MetricKey) {
            $samples = @(Get-OMStat -Resource $resource -Key $key -From $from -ErrorAction SilentlyContinue)
            if (-not $samples) {
                Write-Verbose "No samples for '$key' on '$($resource.Name)'."
                continue
            }

            foreach ($sample in $samples) {
                $records += [pscustomobject]@{
                    Resource     = $resource.Name
                    ResourceKind = $ResourceKind
                    ResourceId   = $resource.Id
                    MetricKey    = $key
                    Time         = $sample.Time
                    Value        = $sample.Value
                    Unit         = $sample.Unit
                }
            }
        }
    }

    $records = @($records | Sort-Object Resource, MetricKey, Time)
    Write-Verbose ("Collected {0} sample(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    if ($connection) { Disconnect-OMServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
