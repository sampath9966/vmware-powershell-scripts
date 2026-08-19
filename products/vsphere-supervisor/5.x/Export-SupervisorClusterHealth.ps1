<#
.SYNOPSIS
    Reports Supervisor cluster config status, version and control plane addresses, plus guest cluster versions.

.DESCRIPTION
    Returns each Supervisor-enabled cluster with its config status, the Kubernetes version it is
    running, its API server address and load balancer configuration - and where the config
    status is not running, the message explaining why.

    Supervisor version drift against the VCF BOM is a real upgrade blocker, and the config
    status message is the first thing support asks for. Both are several clicks apart in the UI.

    Pain area addressed: #3 BOM / version drift per domain; #1 Certificate expiry across the
    stack.

.PARAMETER Server
    FQDN or IP address of the vCenter Server that hosts the Supervisor.

.PARAMETER Credential
    Credential used to authenticate to vCenter Server. Needs Namespaces privileges to read or
    change namespace configuration.

.PARAMETER Cluster
    Limit to these clusters.

.PARAMETER UnhealthyOnly
    Return only clusters whose config status is not running.

.PARAMETER OutputPath
    Path of the file to write. When omitted the records are only returned on the pipeline and
    nothing is written to disk.

.PARAMETER Format
    Output file format. CSV is the flat table, JSON carries the export envelope that the
    matching import script validates, HTML is a styled table for sharing.

.EXAMPLE
    PS> ./Export-SupervisorClusterHealth.ps1 -Server vcenter.example.local -Credential $cred

    Reports the state of every Supervisor cluster.

.NOTES
    Author        : Sampath
    Product       : vSphere with Tanzu (Supervisor and TKG) (VCF 5.x)
    Target        : VMware Cloud Foundation 5.x
    Modules       : VMware.VimAutomation.Core, VMware.VimAutomation.WorkloadManagement, VMware.VimAutomation.Cis.Core
    Behaviour     : Read-only. Collects data and optionally writes it to disk.
    Standalone    : Yes. This script does not dot-source or import any other file
                    in this repository and can be copied out on its own.
#>

#Requires -Version 5.1
#Requires -Modules VMware.VimAutomation.Core
#Requires -Modules VMware.VimAutomation.WorkloadManagement
#Requires -Modules VMware.VimAutomation.Cis.Core

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Server,
    [Parameter(Mandatory)] [System.Management.Automation.PSCredential]$Credential,
    [Parameter()] [string[]]$Cluster,
    [Parameter()] [switch]$UnhealthyOnly,
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
    Schema        = 'supervisor.cluster-health'
    SchemaVersion = '1.0'
    Product       = 'vsphere-supervisor'
    VcfVersion    = '5.x'
    Server        = $Server
}

$connection = $null
try {
    $connection = Connect-VIServer -Server $Server -Credential $Credential -ErrorAction Stop
    $cisConnection = Connect-CisServer -Server $Server -Credential $Credential -ErrorAction Stop
    if (@($DefaultVIServers).Count -gt 1) {
        Write-Warning (("{0} vCenter connections are open in this session. PowerCLI cmdlets act on " +
            "every connected server unless they are scoped, which silently mixes inventories. " +
            "This script scopes its own calls to '{1}'.") -f @($DefaultVIServers).Count, $connection.Name)
    }
    Write-Verbose "Connected to vCenter Server $($connection.Name) and its Automation API endpoint"
    # Scope every call in this script to the connection opened above. Without this,
    # PowerCLI cmdlets act on every connected server, which silently mixes inventories
    # when more than one is connected. The hashtable is cloned first because indexing
    # the inherited one would change the caller's session defaults too.
    $PSDefaultParameterValues = $PSDefaultParameterValues.Clone()
    $PSDefaultParameterValues['*:Server'] = $connection

    $records = @()

    $clusterService = Get-CisService -Name 'com.vmware.vcenter.namespace_management.clusters' -Server $cisConnection -ErrorAction Stop
    $supervisorClusters = @($clusterService.list())
    Write-Verbose ("Found {0} Supervisor-enabled cluster(s)." -f $supervisorClusters.Count)

    foreach ($entry in $supervisorClusters) {
        $clusterName = $entry.cluster_name
        if ($Cluster -and $clusterName -notin $Cluster) { continue }

        $status = [string]$entry.config_status
        $healthy = $status -eq 'RUNNING'
        if ($UnhealthyOnly -and $healthy) { continue }

        $detail = $null
        try { $detail = $clusterService.get($entry.cluster) }
        catch { Write-Verbose "Could not read detail for cluster '$clusterName'." }

        $records += [pscustomobject]@{
            Cluster            = $clusterName
            ClusterId          = $entry.cluster
            ConfigStatus       = $status
            KubernetesStatus   = [string]$entry.kubernetes_status
            Healthy            = $healthy
            ApiServerAddress   = if ($detail) { $detail.api_server_cluster_endpoint } else { '' }
            ApiServerVip       = if ($detail) { $detail.api_server_management_endpoint } else { '' }
            SizingHint         = if ($detail) { [string]$detail.size_hint } else { '' }
            NetworkProvider    = if ($detail) { [string]$detail.network_provider } else { '' }
            StoragePolicy      = if ($detail) { $detail.master_storage_policy } else { '' }
            Message            = if ($detail) { (@($detail.messages.details) -join '; ') } else { '' }
        }
    }

    $records = @($records | Sort-Object Healthy, Cluster)
    Write-Verbose ("Collected {0} Supervisor cluster record(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    if ($cisConnection) { Disconnect-CisServer -Server $cisConnection -Confirm:$false -ErrorAction SilentlyContinue }
    if ($connection) { Disconnect-VIServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
