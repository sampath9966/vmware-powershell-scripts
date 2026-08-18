<#
.SYNOPSIS
    Runs the vSAN health service against every cluster and flattens the results into one row per check.

.DESCRIPTION
    Runs the health service per cluster and walks the nested group and test structure, returning
    one flat row per individual check with its group, status and message - which is what makes
    the output filterable and shareable.

    The health UI is per cluster and mostly green. Filtering this to Status -ne 'green' gives
    the exception list for the whole estate in one table, which is the form the question is
    actually asked in.

    Pain area addressed: #11 vSAN health, capacity, policy compliance.

.PARAMETER Server
    FQDN or IP address of the vCenter Server to connect to.

.PARAMETER Credential
    Credential used to authenticate to vCenter Server.

.PARAMETER Cluster
    Limit to these clusters. Omit to check every vSAN-enabled cluster.

.PARAMETER FailuresOnly
    Return only checks that are not green.

.PARAMETER OutputPath
    Path of the file to write. When omitted the records are only returned on the pipeline and
    nothing is written to disk.

.PARAMETER Format
    Output file format. CSV is the flat table, JSON carries the export envelope that the
    matching import script validates, HTML is a styled table for sharing.

.EXAMPLE
    PS> ./Export-VsanHealthReport.ps1 -Server vcenter.example.local -Credential $cred -FailuresOnly -OutputPath ./vsanhealth.html -Format HTML

    Produces the estate-wide vSAN exception report.

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
    [Parameter()] [switch]$FailuresOnly,
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
    Schema        = 'vsan.health-report'
    SchemaVersion = '1.0'
    Product       = 'vsan'
    VcfVersion    = '9.x'
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
        Write-Verbose "Running the health service against '$($vsanCluster.Name)'. This takes a moment."

        $health = $null
        try {
            $health = Test-VsanClusterHealth -Cluster $vsanCluster -ErrorAction Stop
        }
        catch {
            Write-Warning ("Health service failed on '{0}': {1}" -f $vsanCluster.Name, $_.Exception.Message)
            $records += [pscustomobject]@{
                Cluster = $vsanCluster.Name; Group = '(health service)'; Check = '(unavailable)'
                Status = 'error'; Message = $_.Exception.Message; Timestamp = (Get-Date)
            }
            continue
        }

        foreach ($group in @($health.GroupHealths)) {
            foreach ($test in @($group.TestHealths)) {
                $status = [string]$test.TestHealth
                if ($FailuresOnly -and $status -in @('green', 'skipped')) { continue }

                $records += [pscustomobject]@{
                    Cluster   = $vsanCluster.Name
                    Group     = $group.GroupName
                    Check     = $test.TestName
                    Status    = $status
                    Message   = ($test.TestShortDescription -replace '\s+', ' ')
                    Timestamp = $health.Timestamp
                }
            }
        }

        if (-not @($health.GroupHealths)) {
            $records += [pscustomobject]@{
                Cluster = $vsanCluster.Name; Group = '(overall)'; Check = 'OverallHealth'
                Status = [string]$health.OverallHealth; Message = $health.OverallHealthDescription
                Timestamp = $health.Timestamp
            }
        }
    }

    $records = @($records | Sort-Object Status, Cluster, Group, Check)
    Write-Verbose ("Collected {0} health row(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    if ($connection) { Disconnect-VIServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
