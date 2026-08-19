<#
.SYNOPSIS
    Pulls the CPU and memory rightsizing recommendations Operations has calculated, with the demand history behind each one.

.DESCRIPTION
    Reads every virtual machine resource and the rightsizing metrics Operations maintains -
    recommended vCPU and memory size, current allocation, demand and workload percentages, and
    idle and reclaimable indicators - into one table with the delta already calculated.

    The reclamation view shows this in the UI but exports badly, and the numbers people need to
    justify a change (what it is now, what it should be, how much that saves in aggregate) end
    up retyped into a spreadsheet. This produces that spreadsheet directly.

    Pain area addressed: #14 Rightsizing and idle workloads.

.PARAMETER Server
    FQDN or IP address of the VCF Operations (Aria Operations) analytics node.

.PARAMETER Credential
    Credential used to authenticate to VCF Operations.

.PARAMETER Name
    Limit to these VM names.

.PARAMETER OversizedOnly
    Return only VMs where the recommended size is smaller than the current allocation.

.PARAMETER MinimumCpuDelta
    Only report VMs where the vCPU recommendation differs by at least this many.

.PARAMETER OutputPath
    Path of the file to write. When omitted the records are only returned on the pipeline and
    nothing is written to disk.

.PARAMETER Format
    Output file format. CSV is the flat table, JSON carries the export envelope that the
    matching import script validates, HTML is a styled table for sharing.

.EXAMPLE
    PS> ./Export-OpsRightsizingRecommendation.ps1 -Server ops.example.local -Credential $cred -OversizedOnly -OutputPath ./rightsizing.csv

    Writes the oversized VM list with the recommended sizes.

.EXAMPLE
    PS> ./Export-OpsRightsizingRecommendation.ps1 -Server ops.example.local -Credential $cred | Measure-Object CpuDelta -Sum

    Totals the vCPUs that could be handed back.

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
    [Parameter()] [string[]]$Name,
    [Parameter()] [switch]$OversizedOnly,
    [Parameter()] [int]$MinimumCpuDelta = 0,
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
    Schema        = 'vcf-operations.rightsizing'
    SchemaVersion = '1.0'
    Product       = 'vcf-operations'
    VcfVersion    = '5.x'
    Server        = $Server
}

$connection = $null
try {
    $connection = Connect-OMServer -Server $Server -Credential $Credential -ErrorAction Stop
    Write-Verbose "Connected to VCF Operations $($connection.Name)"

    $records = @()

    $metricKeys = @(
        'cpu|size.recommendation',
        'mem|size.recommendation',
        'cpu|demand_average',
        'mem|workload',
        'summary|oversized',
        'summary|idle'
    )

    $resourceParams = @{ ResourceKind = 'VirtualMachine' }
    if ($Name) { $resourceParams['Name'] = $Name }
    $resources = Get-OMResource @resourceParams
    Write-Verbose ("Operations reports {0} virtual machine resource(s)." -f @($resources).Count)

    foreach ($resource in $resources) {
        $stats = @{}
        foreach ($key in $metricKeys) {
            $stat = Get-OMStat -Resource $resource -Key $key -From (Get-Date).AddDays(-1) -ErrorAction SilentlyContinue |
                Sort-Object Time -Descending | Select-Object -First 1
            if ($stat) { $stats[$key] = $stat.Value }
        }

        $recommendedCpu = $stats['cpu|size.recommendation']
        $recommendedMem = $stats['mem|size.recommendation']
        if ($null -eq $recommendedCpu -and $null -eq $recommendedMem) { continue }

        $currentCpu = ($resource.ExtensionData.ResourceKey.ResourceIdentifiers |
            Where-Object { $_.IdentifierType.Name -eq 'VMEntityName' }).Value

        $cpuDelta = $null
        if ($null -ne $recommendedCpu -and $resource.ExtensionData) {
            $cpuStat = Get-OMStat -Resource $resource -Key 'cpu|numberToBeProvisioned' -From (Get-Date).AddDays(-1) -ErrorAction SilentlyContinue |
                Sort-Object Time -Descending | Select-Object -First 1
            if ($cpuStat) { $cpuDelta = [int]$cpuStat.Value - [int]$recommendedCpu }
        }

        if ($OversizedOnly -and (-not $cpuDelta -or $cpuDelta -le 0)) { continue }
        if ($MinimumCpuDelta -gt 0 -and ([math]::Abs([int]$cpuDelta) -lt $MinimumCpuDelta)) { continue }

        $records += [pscustomobject]@{
            Name             = $resource.Name
            ResourceId       = $resource.Id
            Health           = [string]$resource.Health
            State            = [string]$resource.State
            EntityName       = $currentCpu
            RecommendedVcpu  = $recommendedCpu
            RecommendedMemKB = $recommendedMem
            CpuDelta         = $cpuDelta
            CpuDemandPercent = $stats['cpu|demand_average']
            MemWorkload      = $stats['mem|workload']
            Oversized        = $stats['summary|oversized']
            Idle             = $stats['summary|idle']
        }
    }

    $records = @($records | Sort-Object CpuDelta -Descending)
    Write-Verbose ("Collected {0} rightsizing row(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    if ($connection) { Disconnect-OMServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
