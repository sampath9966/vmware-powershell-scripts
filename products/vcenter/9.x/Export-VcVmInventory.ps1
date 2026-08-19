<#
.SYNOPSIS
    Builds a single flat VM inventory joining host, cluster, datastore, full folder path, tags and custom attributes.

.DESCRIPTION
    Returns one row per VM carrying everything that normally needs three or four separate
    queries: which host and cluster it runs on, which datastores it occupies, its full inventory
    folder path, its resource pool, guest OS and tools state, IP addresses, and every tag and
    custom attribute attached to it.

    The folder path is the part people give up on - the API only gives you the parent, so the
    path has to be walked one parent at a time. This does that walk once and caches it, which is
    why it stays fast on a large inventory.

    Tag retrieval is the slow part on big estates, so it is opt-in through -IncludeTag.

    Pain area addressed: #10 Cross-domain inventory.

.PARAMETER Server
    FQDN or IP address of the vCenter Server to connect to.

.PARAMETER Credential
    Credential used to authenticate to vCenter Server.

.PARAMETER Cluster
    Limit the inventory to VMs in these clusters.

.PARAMETER IncludeTag
    Resolve tag assignments for every VM. Accurate but noticeably slower on large inventories.

.PARAMETER IncludeCustomAttribute
    Include custom attribute (annotation) values as additional columns.

.PARAMETER PoweredOnOnly
    Return only powered-on VMs.

.PARAMETER OutputPath
    Path of the file to write. When omitted the records are only returned on the pipeline and
    nothing is written to disk.

.PARAMETER Format
    Output file format. CSV is the flat table, JSON carries the export envelope that the
    matching import script validates, HTML is a styled table for sharing.

.EXAMPLE
    PS> ./Export-VcVmInventory.ps1 -Server vcenter.example.local -Credential $cred -IncludeTag -OutputPath ./vms.csv

    Writes the full inventory including tags to CSV.

.EXAMPLE
    PS> ./Export-VcVmInventory.ps1 -Server vcenter.example.local -Credential $cred | Group-Object Cluster | Sort-Object Count -Descending

    Counts VMs per cluster.

.NOTES
    Author        : Sampath
    Product       : vCenter (VCF 9.x)
    Target        : VMware Cloud Foundation 9.x
    Modules       : VMware.VimAutomation.Core, VMware.VimAutomation.Core
    Behaviour     : Read-only. Collects data and optionally writes it to disk.
    Standalone    : Yes. This script does not dot-source or import any other file
                    in this repository and can be copied out on its own.
#>

#Requires -Version 5.1
#Requires -Modules VMware.VimAutomation.Core
#Requires -Modules VMware.VimAutomation.Core

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Server,
    [Parameter(Mandatory)] [System.Management.Automation.PSCredential]$Credential,
    [Parameter()] [string[]]$Cluster,
    [Parameter()] [switch]$IncludeTag,
    [Parameter()] [switch]$IncludeCustomAttribute,
    [Parameter()] [switch]$PoweredOnOnly,
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
    Schema        = 'vcenter.vm-inventory'
    SchemaVersion = '1.0'
    Product       = 'vcenter'
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

    $records = @()

    $folderPathCache = @{}
    function Get-InventoryPath {
        param($Item)

        if (-not $Item) { return '' }
        $key = $Item.Id
        if ($folderPathCache.ContainsKey($key)) { return $folderPathCache[$key] }

        $segments = @()
        $cursor = $Item
        while ($cursor -and $cursor.Name -ne 'vm' -and $cursor.Name -ne 'Datacenters') {
            $segments = @($cursor.Name) + $segments
            $cursor = $cursor.Parent
        }

        $path = '/' + ($segments -join '/')
        $folderPathCache[$key] = $path
        return $path
    }

    $vmFilter = @{}
    if ($Cluster) { $vmFilter['Location'] = Get-Cluster -Name $Cluster }
    $vms = Get-VM @vmFilter
    Write-Verbose ("Retrieved {0} VM(s)." -f @($vms).Count)

    $tagsByVm = @{}
    if ($IncludeTag) {
        Write-Verbose 'Resolving tag assignments. This is the slow part.'
        foreach ($assignment in (Get-TagAssignment -Entity $vms)) {
            $id = $assignment.Entity.Id
            if (-not $tagsByVm.ContainsKey($id)) { $tagsByVm[$id] = @() }
            $tagsByVm[$id] += ('{0}/{1}' -f $assignment.Tag.Category.Name, $assignment.Tag.Name)
        }
    }

    foreach ($vm in $vms) {
        if ($PoweredOnOnly -and $vm.PowerState -ne 'PoweredOn') { continue }

        $vmHost = $vm.VMHost
        $record = [ordered]@{
            Name           = $vm.Name
            PowerState     = [string]$vm.PowerState
            FolderPath     = Get-InventoryPath -Item $vm.Folder
            Cluster        = if ($vmHost) { [string]$vmHost.Parent } else { '' }
            VMHost         = if ($vmHost) { $vmHost.Name } else { '' }
            ResourcePool   = [string]$vm.ResourcePool
            NumCpu         = $vm.NumCpu
            CoresPerSocket = $vm.CoresPerSocket
            MemoryGB       = $vm.MemoryGB
            ProvisionedGB  = [math]::Round($vm.ProvisionedSpaceGB, 1)
            UsedGB         = [math]::Round($vm.UsedSpaceGB, 1)
            Datastore      = ((Get-Datastore -RelatedObject $vm -ErrorAction SilentlyContinue).Name | Sort-Object -Unique) -join '; '
            GuestOS        = $vm.Guest.OSFullName
            ToolsStatus    = $vm.ExtensionData.Guest.ToolsStatus
            ToolsVersion   = $vm.ExtensionData.Guest.ToolsVersionStatus2
            HardwareVersion = $vm.HardwareVersion
            IPAddress      = ($vm.Guest.IPAddress -join '; ')
            Notes          = $vm.Notes
            VmId           = $vm.Id
        }

        if ($IncludeTag) {
            $record['Tags'] = ($tagsByVm[$vm.Id] | Sort-Object) -join '; '
        }

        if ($IncludeCustomAttribute) {
            foreach ($annotation in (Get-Annotation -Entity $vm -ErrorAction SilentlyContinue)) {
                if ($annotation.Value) { $record['CA_' + $annotation.Name] = $annotation.Value }
            }
        }

        $records += [pscustomobject]$record
    }

    $records = @($records | Sort-Object Cluster, Name)
    Write-Verbose ("Collected {0} VM record(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    if ($connection) { Disconnect-VIServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
