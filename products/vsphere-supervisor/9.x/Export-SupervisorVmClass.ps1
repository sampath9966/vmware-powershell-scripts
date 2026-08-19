<#
.SYNOPSIS
    Exports VM classes with their CPU, memory and reservation settings, and the namespaces each is bound to.

.DESCRIPTION
    Returns each VM class with the vCPU count, memory, CPU and memory reservations it defines,
    and the list of namespaces that have it available.

    Custom VM classes are a common source of 'the deployment will not schedule': the class
    exists but was never bound to the namespace. This makes the binding visible, and the file is
    what Import-SupervisorVmClass.ps1 replays.

    Pain area addressed: #16 Config portability between environments.

.PARAMETER Server
    FQDN or IP address of the vCenter Server that hosts the Supervisor.

.PARAMETER Credential
    Credential used to authenticate to vCenter Server. Needs Namespaces privileges to read or
    change namespace configuration.

.PARAMETER ClassName
    Limit to these VM class names.

.PARAMETER UnboundOnly
    Return only VM classes that are not bound to any namespace.

.PARAMETER OutputPath
    Path of the file to write. When omitted the records are only returned on the pipeline and
    nothing is written to disk.

.PARAMETER Format
    Output file format. CSV is the flat table, JSON carries the export envelope that the
    matching import script validates, HTML is a styled table for sharing.

.EXAMPLE
    PS> ./Export-SupervisorVmClass.ps1 -Server vcenter.example.local -Credential $cred -UnboundOnly

    Finds VM classes no namespace can actually use.

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
    [Parameter()] [string[]]$ClassName,
    [Parameter()] [switch]$UnboundOnly,
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
    Schema        = 'supervisor.vm-class'
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
    # Scope every call in this script to the connection opened above. Without this,
    # PowerCLI cmdlets act on every connected server, which silently mixes inventories
    # when more than one is connected. The hashtable is cloned first because indexing
    # the inherited one would change the caller's session defaults too.
    $PSDefaultParameterValues = $PSDefaultParameterValues.Clone()
    $PSDefaultParameterValues['*:Server'] = $connection

    $records = @()

    $classService = Get-CisService -Name 'com.vmware.vcenter.namespace_management.virtual_machine_classes' -Server $cisConnection -ErrorAction Stop
    $namespaceService = Get-CisService -Name 'com.vmware.vcenter.namespaces.instances' -Server $cisConnection -ErrorAction Stop

    $namespacesByClass = @{}
    foreach ($entry in @($namespaceService.list())) {
        $detail = $null
        try { $detail = $namespaceService.get($entry.namespace) } catch { continue }
        foreach ($className in @($detail.vm_service_spec.vm_classes)) {
            if (-not $namespacesByClass.ContainsKey($className)) { $namespacesByClass[$className] = @() }
            $namespacesByClass[$className] += $entry.namespace
        }
    }

    $classes = @($classService.list())
    Write-Verbose ("Found {0} VM class(es)." -f $classes.Count)

    foreach ($entry in $classes) {
        $name = $entry.id
        if ($ClassName -and $name -notin $ClassName) { continue }

        $boundTo = @()
        if ($namespacesByClass.ContainsKey($name)) { $boundTo = $namespacesByClass[$name] }
        if ($UnboundOnly -and $boundTo.Count -gt 0) { continue }

        $detail = $null
        try { $detail = $classService.get($name) } catch { Write-Verbose "Could not read VM class '$name'." }

        $records += [pscustomobject]@{
            Name             = $name
            CpuCount         = if ($detail) { $detail.cpu_count } else { $entry.cpu_count }
            MemoryMB         = if ($detail) { $detail.memory_MB } else { $entry.memory_MB }
            CpuReservation   = if ($detail) { $detail.cpu_reservation } else { $null }
            MemoryReservation = if ($detail) { $detail.memory_reservation } else { $null }
            Devices          = if ($detail) { (@($detail.devices.vgpu_devices.profile_name) -join '; ') } else { '' }
            BoundNamespaces  = ($boundTo -join '; ')
            BoundCount       = $boundTo.Count
        }
    }

    $records = @($records | Sort-Object Name)
    Write-Verbose ("Collected {0} VM class record(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    if ($cisConnection) { Disconnect-CisServer -Server $cisConnection -Confirm:$false -ErrorAction SilentlyContinue }
    if ($connection) { Disconnect-VIServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
