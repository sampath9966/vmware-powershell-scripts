<#
.SYNOPSIS
    Lists every Supervisor namespace with its cluster, resource limits, storage policies, VM classes and access list.

.DESCRIPTION
    One row per namespace carrying the Supervisor cluster it belongs to, its config status, the
    CPU, memory and storage limits applied to it, the storage policies and VM classes bound to
    it, and the subjects that have access with their role.

    This is the join nobody has: the platform team needs to know which namespace is consuming
    which storage policy, and the application team needs to know what their limits actually are.
    Both are here, and the file feeds Import-SupervisorNamespaceConfig.ps1.

    Pain area addressed: #10 Cross-domain inventory.

.PARAMETER Server
    FQDN or IP address of the vCenter Server that hosts the Supervisor.

.PARAMETER Credential
    Credential used to authenticate to vCenter Server. Needs Namespaces privileges to read or
    change namespace configuration.

.PARAMETER Cluster
    Limit to namespaces on these Supervisor clusters.

.PARAMETER NamespaceName
    Limit to these namespace names.

.PARAMETER OutputPath
    Path of the file to write. When omitted the records are only returned on the pipeline and
    nothing is written to disk.

.PARAMETER Format
    Output file format. CSV is the flat table, JSON carries the export envelope that the
    matching import script validates, HTML is a styled table for sharing.

.EXAMPLE
    PS> ./Export-SupervisorNamespaceInventory.ps1 -Server vcenter.example.local -Credential $cred -OutputPath ./namespaces.json -Format JSON

    Captures the namespace configuration for review or replay.

.EXAMPLE
    PS> ./Export-SupervisorNamespaceInventory.ps1 -Server vcenter.example.local -Credential $cred | Where-Object { -not $_.CpuLimitMHz }

    Finds namespaces running with no CPU limit at all.

.NOTES
    Author        : Sampath
    Product       : vSphere Supervisor and VKS (VCF 9.x)
    Target        : VMware Cloud Foundation 9.x
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
    [Parameter()] [string[]]$NamespaceName,
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
    Schema        = 'supervisor.namespace-inventory'
    SchemaVersion = '1.0'
    Product       = 'vsphere-supervisor'
    VcfVersion    = '9.x'
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

    $records = @()

    $namespaceService = Get-CisService -Name 'com.vmware.vcenter.namespaces.instances' -ErrorAction Stop
    $namespaces = @($namespaceService.list())
    Write-Verbose ("The Supervisor reports {0} namespace(s)." -f $namespaces.Count)

    foreach ($entry in $namespaces) {
        $name = $entry.namespace
        if ($NamespaceName -and $name -notin $NamespaceName) { continue }

        $detail = $null
        try { $detail = $namespaceService.get($name) }
        catch {
            Write-Warning ("Could not read namespace '{0}': {1}" -f $name, $_.Exception.Message)
            continue
        }

        $clusterName = ''
        try {
            $cluster = Get-Cluster -Id ('ClusterComputeResource-' + $detail.cluster) -ErrorAction SilentlyContinue
            if ($cluster) { $clusterName = $cluster.Name }
        }
        catch { Write-Verbose "Could not resolve the cluster id for namespace '$name'." }

        if ($Cluster -and $clusterName -notin $Cluster) { continue }

        $cpuLimit = $null
        $memoryLimit = $null
        foreach ($limit in @($detail.resource_spec)) {
            if ($limit.cpu_limit) { $cpuLimit = $limit.cpu_limit }
            if ($limit.memory_limit) { $memoryLimit = $limit.memory_limit }
        }

        $storagePolicies = @()
        $storageLimit = 0
        foreach ($storage in @($detail.storage_specs)) {
            $storagePolicies += $storage.policy
            if ($storage.limit) { $storageLimit += [int]$storage.limit }
        }

        $access = @()
        foreach ($subject in @($detail.access_list)) {
            $access += ('{0}\{1}:{2}' -f $subject.domain, $subject.subject, $subject.role)
        }

        $records += [pscustomobject]@{
            Namespace       = $name
            Cluster         = $clusterName
            ClusterId       = $detail.cluster
            ConfigStatus    = [string]$detail.config_status
            Description     = $detail.description
            CpuLimitMHz     = $cpuLimit
            MemoryLimitMB   = $memoryLimit
            StorageLimitMB  = $storageLimit
            StoragePolicies = ($storagePolicies -join '; ')
            VmClasses       = (@($detail.vm_service_spec.vm_classes) -join '; ')
            ContentLibraries = (@($detail.vm_service_spec.content_libraries) -join '; ')
            AccessList      = ($access -join '; ')
            AccessCount     = @($access).Count
        }
    }

    $records = @($records | Sort-Object Cluster, Namespace)
    Write-Verbose ("Collected {0} namespace record(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    if ($cisConnection) { Disconnect-CisServer -Server $cisConnection -Confirm:$false -ErrorAction SilentlyContinue }
    if ($connection) { Disconnect-VIServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
