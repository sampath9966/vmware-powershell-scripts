<#
.SYNOPSIS
    Lists VMs whose storage policy compliance is not compliant, alongside any components currently resyncing.

.DESCRIPTION
    Walks the SPBM entity configuration for every VM and its disks, returning anything whose
    compliance status is not compliant, then adds the current resync picture - how many
    components, how many bytes left to sync, and the estimated time remaining.

    Out-of-policy objects and long-running resyncs are the two things that turn a routine host
    evacuation into an incident, and neither is visible from a single screen across clusters.

    Pain area addressed: #11 vSAN health, capacity, policy compliance.

.PARAMETER Server
    FQDN or IP address of the vCenter Server to connect to.

.PARAMETER Credential
    Credential used to authenticate to vCenter Server.

.PARAMETER Cluster
    Limit to these clusters.

.PARAMETER IncludeCompliant
    Include objects that are compliant. Off by default.

.PARAMETER OutputPath
    Path of the file to write. When omitted the records are only returned on the pipeline and
    nothing is written to disk.

.PARAMETER Format
    Output file format. CSV is the flat table, JSON carries the export envelope that the
    matching import script validates, HTML is a styled table for sharing.

.EXAMPLE
    PS> ./Export-VsanObjectCompliance.ps1 -Server vcenter.example.local -Credential $cred -OutputPath ./compliance.csv

    Writes the non-compliant object list plus current resync state.

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
    [Parameter()] [switch]$IncludeCompliant,
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
    Schema        = 'vsan.object-compliance'
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
    Write-Verbose ("Checking {0} vSAN-enabled cluster(s)." -f @($clusters).Count)

    foreach ($vsanCluster in $clusters) {
        foreach ($vm in (Get-VM -Location $vsanCluster)) {
            foreach ($entity in (Get-SpbmEntityConfiguration -VM $vm -ErrorAction SilentlyContinue)) {
                $status = [string]$entity.ComplianceStatus
                if (-not $IncludeCompliant -and $status -eq 'compliant') { continue }

                $records += [pscustomobject]@{
                    Kind             = 'Object'
                    Cluster          = $vsanCluster.Name
                    VM               = $vm.Name
                    Entity           = [string]$entity.Entity
                    StoragePolicy    = [string]$entity.StoragePolicy
                    ComplianceStatus = $status
                    TimeOfCheck      = $entity.TimeOfCheck
                    Components       = $null
                    BytesToSyncGB    = $null
                    EtaMinutes       = $null
                }
            }

            foreach ($disk in (Get-HardDisk -VM $vm -ErrorAction SilentlyContinue)) {
                foreach ($entity in (Get-SpbmEntityConfiguration -HardDisk $disk -ErrorAction SilentlyContinue)) {
                    $status = [string]$entity.ComplianceStatus
                    if (-not $IncludeCompliant -and $status -eq 'compliant') { continue }

                    $records += [pscustomobject]@{
                        Kind             = 'Disk'
                        Cluster          = $vsanCluster.Name
                        VM               = $vm.Name
                        Entity           = $disk.Name
                        StoragePolicy    = [string]$entity.StoragePolicy
                        ComplianceStatus = $status
                        TimeOfCheck      = $entity.TimeOfCheck
                        Components       = $null
                        BytesToSyncGB    = $null
                        EtaMinutes       = $null
                    }
                }
            }
        }

        $resync = @(Get-VsanResyncingComponent -Cluster $vsanCluster -ErrorAction SilentlyContinue)
        if ($resync) {
            $bytes = ($resync | Measure-Object -Property BytesToSync -Sum).Sum
            $records += [pscustomobject]@{
                Kind             = 'Resync'
                Cluster          = $vsanCluster.Name
                VM               = ''
                Entity           = '(cluster resync)'
                StoragePolicy    = ''
                ComplianceStatus = 'resyncing'
                TimeOfCheck      = (Get-Date)
                Components       = @($resync).Count
                BytesToSyncGB    = [math]::Round([double]$bytes / 1GB, 2)
                EtaMinutes       = ($resync | Measure-Object -Property EtaToComplete -Maximum).Maximum
            }
        }
    }

    $records = @($records | Sort-Object Kind, Cluster, VM)
    Write-Verbose ("Collected {0} compliance and resync row(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    if ($connection) { Disconnect-VIServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
