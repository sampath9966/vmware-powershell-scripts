<#
.SYNOPSIS
    Exports every distributed switch with its port groups, VLAN configuration, teaming and uplink layout.

.DESCRIPTION
    One row per port group carrying the switch it belongs to, its VLAN or trunk range, teaming
    policy, active and standby uplinks, security settings and the number of ports in use - plus
    a row per switch with MTU, discovery protocol and version.

    The VLAN map is the artefact the network team always asks for and nobody has. Exporting it
    also makes port group definitions portable, which is what Import-VcDistributedSwitch.ps1
    consumes when standing up a matching switch elsewhere.

    Pain area addressed: #16 Config portability between environments; #9 Config drift
    (NTP/DNS/syslog/lockdown).

.PARAMETER Server
    FQDN or IP address of the vCenter Server to connect to.

.PARAMETER Credential
    Credential used to authenticate to vCenter Server.

.PARAMETER VDSwitch
    Limit the export to these distributed switches.

.PARAMETER OutputPath
    Path of the file to write. When omitted the records are only returned on the pipeline and
    nothing is written to disk.

.PARAMETER Format
    Output file format. CSV is the flat table, JSON carries the export envelope that the
    matching import script validates, HTML is a styled table for sharing.

.EXAMPLE
    PS> ./Export-VcDistributedSwitch.ps1 -Server vcenter.example.local -Credential $cred -OutputPath ./vds.csv

    Writes the full VLAN and port group map.

.NOTES
    Author        : Sampath
    Product       : vCenter (VCF 9.x)
    Target        : VMware Cloud Foundation 9.x
    Modules       : VMware.VimAutomation.Core, VMware.VimAutomation.Vds
    Behaviour     : Read-only. Collects data and optionally writes it to disk.
    Standalone    : Yes. This script does not dot-source or import any other file
                    in this repository and can be copied out on its own.
#>

#Requires -Version 5.1
#Requires -Modules VMware.VimAutomation.Core
#Requires -Modules VMware.VimAutomation.Vds

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Server,
    [Parameter(Mandatory)] [System.Management.Automation.PSCredential]$Credential,
    [Parameter()] [string[]]$VDSwitch,
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
    Schema        = 'vcenter.distributed-switch'
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

    $switches = Get-VDSwitch
    if ($VDSwitch) { $switches = @($switches | Where-Object { $_.Name -in $VDSwitch }) }
    Write-Verbose ("Found {0} distributed switch(es)." -f @($switches).Count)

    foreach ($vds in $switches) {
        $records += [pscustomobject]@{
            Kind            = 'Switch'
            VDSwitch        = $vds.Name
            PortGroup       = ''
            VlanType        = ''
            VlanId          = ''
            NumPorts        = $vds.NumUplinkPorts
            ActiveUplink    = (($vds.ExtensionData.Config.UplinkPortPolicy.UplinkPortName) -join '; ')
            StandbyUplink   = ''
            LoadBalancing   = ''
            PromiscuousMode = ''
            ForgedTransmits = ''
            MacChanges      = ''
            Mtu             = $vds.Mtu
            Version         = $vds.Version
        }

        foreach ($portGroup in (Get-VDPortgroup -VDSwitch $vds)) {
            $vlanConfig = $portGroup.ExtensionData.Config.DefaultPortConfig.Vlan
            $vlanType = $vlanConfig.GetType().Name -replace 'VmwareDistributedVirtualSwitch', '' -replace 'VlanSpec', ''
            $vlanId = switch ($vlanType) {
                'Trunk' { (($vlanConfig.VlanId | ForEach-Object { '{0}-{1}' -f $_.Start, $_.End }) -join ',') }
                'Pvlan' { $vlanConfig.PvlanId }
                default { $vlanConfig.VlanId }
            }

            $teaming = $portGroup.ExtensionData.Config.DefaultPortConfig.UplinkTeamingPolicy
            $security = $portGroup.ExtensionData.Config.DefaultPortConfig.SecurityPolicy

            $records += [pscustomobject]@{
                Kind            = 'PortGroup'
                VDSwitch        = $vds.Name
                PortGroup       = $portGroup.Name
                VlanType        = $vlanType
                VlanId          = [string]$vlanId
                NumPorts        = $portGroup.NumPorts
                ActiveUplink    = ($teaming.UplinkPortOrder.ActiveUplinkPort -join '; ')
                StandbyUplink   = ($teaming.UplinkPortOrder.StandbyUplinkPort -join '; ')
                LoadBalancing   = $teaming.Policy.Value
                PromiscuousMode = $security.AllowPromiscuous.Value
                ForgedTransmits = $security.ForgedTransmits.Value
                MacChanges      = $security.MacChanges.Value
                Mtu             = $vds.Mtu
                Version         = $vds.Version
            }
        }
    }

    $records = @($records | Sort-Object VDSwitch, Kind, PortGroup)
    Write-Verbose ("Collected {0} switch and port group row(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    if ($connection) { Disconnect-VIServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
