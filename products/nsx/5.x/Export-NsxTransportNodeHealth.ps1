<#
.SYNOPSIS
    Reports every transport and edge node with its configuration state, tunnel status and node version.

.DESCRIPTION
    One row per transport node carrying its type, the transport zones it belongs to, the host
    switch and uplink profile in use, its configuration and connectivity state, and the number
    of tunnels that are up versus down.

    Tunnel state is the number that matters and the one buried deepest. A single node with half
    its tunnels down is invisible on the dashboard and very visible to the workloads on it.

    Pain area addressed: #9 Config drift (NTP/DNS/syslog/lockdown).

.PARAMETER Server
    FQDN or IP address of the NSX Manager to connect to.

.PARAMETER Credential
    Credential used to authenticate to NSX Manager.

.PARAMETER NodeType
    Limit to these node types, for example HostNode or EdgeNode.

.PARAMETER UnhealthyOnly
    Return only nodes that are not fully up.

.PARAMETER OutputPath
    Path of the file to write. When omitted the records are only returned on the pipeline and
    nothing is written to disk.

.PARAMETER Format
    Output file format. CSV is the flat table, JSON carries the export envelope that the
    matching import script validates, HTML is a styled table for sharing.

.EXAMPLE
    PS> ./Export-NsxTransportNodeHealth.ps1 -Server nsx.example.local -Credential $cred -UnhealthyOnly

    Lists only nodes with a degraded state or a down tunnel.

.NOTES
    Author        : Sampath
    Product       : NSX-T Data Center (VCF 5.x)
    Target        : VMware Cloud Foundation 5.x
    Modules       : VMware.VimAutomation.Nsxt
    Behaviour     : Read-only. Collects data and optionally writes it to disk.
    Standalone    : Yes. This script does not dot-source or import any other file
                    in this repository and can be copied out on its own.
#>

#Requires -Version 5.1
#Requires -Modules VMware.VimAutomation.Nsxt

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Server,
    [Parameter(Mandatory)] [System.Management.Automation.PSCredential]$Credential,
    [Parameter()] [string[]]$NodeType,
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
    Schema        = 'nsx.transport-node'
    SchemaVersion = '1.0'
    Product       = 'nsx'
    VcfVersion    = '5.x'
    Server        = $Server
}

$connection = $null
try {
    $connection = Connect-NsxtServer -Server $Server -Credential $Credential -ErrorAction Stop
    Write-Verbose "Connected to NSX Manager $($connection.Name)"

    $records = @()

    $nodeService = Get-NsxtService -Name 'com.vmware.nsx.transport_nodes'
    $stateService = Get-NsxtService -Name 'com.vmware.nsx.transport_nodes.state'
    $zoneService = Get-NsxtService -Name 'com.vmware.nsx.transport_zones'

    $zoneNameById = @{}
    foreach ($zone in @($zoneService.list().results)) { $zoneNameById[$zone.id] = $zone.display_name }

    $nodes = @($nodeService.list().results)
    Write-Verbose ("Found {0} transport node(s)." -f $nodes.Count)

    foreach ($node in $nodes) {
        $type = $node.node_deployment_info.resource_type
        if ($NodeType -and $type -notin $NodeType) { continue }

        $state = $null
        try { $state = $stateService.get($node.id) }
        catch { Write-Verbose "Could not read state for '$($node.display_name)'." }

        $zones = @()
        foreach ($endpoint in @($node.transport_zone_endpoints)) {
            $zones += if ($zoneNameById.ContainsKey($endpoint.transport_zone_id)) { $zoneNameById[$endpoint.transport_zone_id] } else { $endpoint.transport_zone_id }
        }

        $tunnelsUp = 0
        $tunnelsDown = 0
        if ($state -and $state.tunnel_status) {
            $tunnelsUp = [int]$state.tunnel_status.up_tunnels_count
            $tunnelsDown = [int]$state.tunnel_status.down_tunnels_count
        }

        $configState = if ($state) { $state.state } else { 'unknown' }
        $healthy = ($configState -eq 'success') -and ($tunnelsDown -eq 0)
        if ($UnhealthyOnly -and $healthy) { continue }

        $records += [pscustomobject]@{
            Node           = $node.display_name
            NodeId         = $node.id
            NodeType       = $type
            Version        = $node.node_deployment_info.node_settings.hostname
            OsType         = $node.node_deployment_info.os_type
            IpAddress      = ($node.node_deployment_info.ip_addresses -join '; ')
            TransportZones = ($zones -join '; ')
            HostSwitch     = ($node.host_switch_spec.host_switches.host_switch_name -join '; ')
            UplinkProfile  = ($node.host_switch_spec.host_switches.uplink_name -join '; ')
            ConfigState    = $configState
            TunnelsUp      = $tunnelsUp
            TunnelsDown    = $tunnelsDown
            Healthy        = $healthy
        }
    }

    $records = @($records | Sort-Object Healthy, NodeType, Node)
    Write-Verbose ("Collected {0} transport node record(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    if ($connection) { Disconnect-NsxtServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
