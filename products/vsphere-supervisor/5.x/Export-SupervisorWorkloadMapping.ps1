<#
.SYNOPSIS
    Maps every Supervisor-managed VM back to its namespace, guest cluster and role in that cluster.

.DESCRIPTION
    Walks the VMs in the vSphere inventory that belong to a Supervisor namespace and returns the
    namespace, the guest cluster the VM is part of where it is one, its role - control plane or
    worker - plus its host, power state and resource allocation.

    When a Kubernetes node is misbehaving, this is the translation layer: it turns a node name
    the platform team cannot find into a VM on a host they can. Nothing in either UI does that.

    Pain area addressed: #10 Cross-domain inventory.

.PARAMETER Server
    FQDN or IP address of the vCenter Server that hosts the Supervisor.

.PARAMETER Credential
    Credential used to authenticate to vCenter Server. Needs Namespaces privileges to read or
    change namespace configuration.

.PARAMETER NamespaceName
    Limit to VMs in these namespaces.

.PARAMETER ControlPlaneOnly
    Return only control plane VMs.

.PARAMETER OutputPath
    Path of the file to write. When omitted the records are only returned on the pipeline and
    nothing is written to disk.

.PARAMETER Format
    Output file format. CSV is the flat table, JSON carries the export envelope that the
    matching import script validates, HTML is a styled table for sharing.

.EXAMPLE
    PS> ./Export-SupervisorWorkloadMapping.ps1 -Server vcenter.example.local -Credential $cred -OutputPath ./k8smap.csv

    Writes the VM to namespace to guest cluster map.

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
    [Parameter()] [string[]]$NamespaceName,
    [Parameter()] [switch]$ControlPlaneOnly,
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
    Schema        = 'supervisor.workload-mapping'
    SchemaVersion = '1.0'
    Product       = 'vsphere-supervisor'
    VcfVersion    = '5.x'
    Server        = $Server
}

$connection = $null
try {
    $connection = Connect-VIServer -Server $Server -Credential $Credential -ErrorAction Stop
    $cisConnection = Connect-CisServer -Server $Server -Credential $Credential -ErrorAction Stop
    Write-Verbose "Connected to vCenter Server $($connection.Name) and its Automation API endpoint"

    $records = @()

    $namespaceService = Get-CisService -Name 'com.vmware.vcenter.namespaces.instances' -ErrorAction Stop
    $namespaceNames = @(@($namespaceService.list()).namespace)
    Write-Verbose ("The Supervisor reports {0} namespace(s)." -f $namespaceNames.Count)

    foreach ($namespace in $namespaceNames) {
        if ($NamespaceName -and $namespace -notin $NamespaceName) { continue }

        $folder = Get-Folder -Name $namespace -ErrorAction SilentlyContinue
        if (-not $folder) {
            Write-Verbose "No inventory folder for namespace '$namespace'."
            continue
        }

        foreach ($vm in (Get-VM -Location $folder -ErrorAction SilentlyContinue)) {
            $role = if ($vm.Name -match 'control-plane|master') { 'ControlPlane' }
                    elseif ($vm.Name -match 'workers|worker|nodepool') { 'Worker' }
                    else { 'Other' }

            if ($ControlPlaneOnly -and $role -ne 'ControlPlane') { continue }

            $guestCluster = ''
            if ($vm.Name -match '^(?<cluster>.+?)-(control-plane|workers|worker|nodepool)') {
                $guestCluster = $Matches['cluster']
            }

            $records += [pscustomobject]@{
                Namespace    = $namespace
                GuestCluster = $guestCluster
                VM           = $vm.Name
                Role         = $role
                PowerState   = [string]$vm.PowerState
                VMHost       = $vm.VMHost.Name
                Cluster      = [string]$vm.VMHost.Parent
                NumCpu       = $vm.NumCpu
                MemoryGB     = $vm.MemoryGB
                ProvisionedGB = [math]::Round($vm.ProvisionedSpaceGB, 1)
                IPAddress    = ($vm.Guest.IPAddress -join '; ')
            }
        }
    }

    $records = @($records | Sort-Object Namespace, GuestCluster, Role, VM)
    Write-Verbose ("Collected {0} workload row(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    if ($cisConnection) { Disconnect-CisServer -Server $cisConnection -Confirm:$false -ErrorAction SilentlyContinue }
    if ($connection) { Disconnect-VIServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
