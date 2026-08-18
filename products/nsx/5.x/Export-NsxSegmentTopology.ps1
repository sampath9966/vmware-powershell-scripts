<#
.SYNOPSIS
    Exports every segment with its subnets, transport zone and the tier-1 and tier-0 it connects through.

.DESCRIPTION
    Builds the logical topology as a table: each segment with its gateway subnets, VLAN or
    overlay type, transport zone, the tier-1 it attaches to, and the tier-0 that tier-1 connects
    up to - so the whole north-south path for a workload is on one row.

    Working this out from the UI means opening three different screens and remembering what was
    on the first. It is also the definition Import-NsxSegment.ps1 replays.

    Pain area addressed: #16 Config portability between environments; #10 Cross-domain
    inventory.

.PARAMETER Server
    FQDN or IP address of the NSX Manager to connect to.

.PARAMETER Credential
    Credential used to authenticate to NSX Manager.

.PARAMETER SegmentName
    Limit to these segment names.

.PARAMETER DisconnectedOnly
    Return only segments not attached to any tier-1 or tier-0 - usually leftovers.

.PARAMETER OutputPath
    Path of the file to write. When omitted the records are only returned on the pipeline and
    nothing is written to disk.

.PARAMETER Format
    Output file format. CSV is the flat table, JSON carries the export envelope that the
    matching import script validates, HTML is a styled table for sharing.

.EXAMPLE
    PS> ./Export-NsxSegmentTopology.ps1 -Server nsx.example.local -Credential $cred -OutputPath ./segments.csv

    Writes the whole logical topology as a table.

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
    [Parameter()] [string[]]$SegmentName,
    [Parameter()] [switch]$DisconnectedOnly,
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
    Schema        = 'nsx.segment-topology'
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

    $segmentService = Get-NsxtPolicyService -Name 'com.vmware.nsx_policy.infra.segments'
    $tier1Service = Get-NsxtPolicyService -Name 'com.vmware.nsx_policy.infra.tier_1s'
    $tier0Service = Get-NsxtPolicyService -Name 'com.vmware.nsx_policy.infra.tier_0s'

    $tier1ByPath = @{}
    foreach ($tier1 in @($tier1Service.list().results)) { $tier1ByPath[$tier1.path] = $tier1 }

    $tier0ByPath = @{}
    foreach ($tier0 in @($tier0Service.list().results)) { $tier0ByPath[$tier0.path] = $tier0 }

    $segments = @($segmentService.list().results)
    if ($SegmentName) { $segments = @($segments | Where-Object { $_.display_name -in $SegmentName }) }
    Write-Verbose ("Found {0} segment(s), {1} tier-1 and {2} tier-0 gateway(s)." -f `
        $segments.Count, $tier1ByPath.Count, $tier0ByPath.Count)

    foreach ($segment in $segments) {
        $tier1 = $null
        $tier0 = $null

        if ($segment.connectivity_path) {
            if ($tier1ByPath.ContainsKey($segment.connectivity_path)) {
                $tier1 = $tier1ByPath[$segment.connectivity_path]
                if ($tier1.tier0_path -and $tier0ByPath.ContainsKey($tier1.tier0_path)) {
                    $tier0 = $tier0ByPath[$tier1.tier0_path]
                }
            }
            elseif ($tier0ByPath.ContainsKey($segment.connectivity_path)) {
                $tier0 = $tier0ByPath[$segment.connectivity_path]
            }
        }

        if ($DisconnectedOnly -and ($tier1 -or $tier0)) { continue }

        $subnets = @()
        foreach ($subnet in @($segment.subnets)) { $subnets += $subnet.gateway_address }

        $records += [pscustomobject]@{
            Segment        = $segment.display_name
            SegmentId      = $segment.id
            Type           = if ($segment.vlan_ids) { 'VLAN' } else { 'Overlay' }
            VlanIds        = ($segment.vlan_ids -join ',')
            Subnets        = ($subnets -join '; ')
            DhcpConfig     = $segment.dhcp_config_path
            TransportZone  = if ($segment.transport_zone_path) { ($segment.transport_zone_path -split '/')[-1] } else { '' }
            Tier1          = if ($tier1) { $tier1.display_name } else { '' }
            Tier0          = if ($tier0) { $tier0.display_name } else { '' }
            Tier0HaMode    = if ($tier0) { $tier0.ha_mode } else { '' }
            AdminState     = $segment.admin_state
            Connected      = [bool]($tier1 -or $tier0)
        }
    }

    $records = @($records | Sort-Object Tier0, Tier1, Segment)
    Write-Verbose ("Collected {0} segment record(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    if ($connection) { Disconnect-NsxtServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
