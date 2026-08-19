<#
.SYNOPSIS
    Reports where each host writes its coredump, scratch and logs, and flags the ones still on non-persistent storage.

.DESCRIPTION
    For every host: the configured and running scratch location, whether the log directory is on
    persistent storage, the coredump partition and network coredump target, and a Compliant
    column that is false when logs or dumps would be lost on reboot.

    This is the check that only gets run after an outage, when the logs needed to explain it
    turn out to have been in a ramdisk. Invoke-EsxLogConfigRemediation.ps1 fixes the rows this
    marks non-compliant.

    Pain area addressed: #9 Config drift (NTP/DNS/syslog/lockdown).

.PARAMETER Server
    FQDN or IP address of the vCenter Server to connect to.

.PARAMETER Credential
    Credential used to authenticate to vCenter Server.

.PARAMETER Cluster
    Limit to hosts in these clusters.

.PARAMETER NonCompliantOnly
    Return only hosts whose logs or dumps are not on persistent storage.

.PARAMETER OutputPath
    Path of the file to write. When omitted the records are only returned on the pipeline and
    nothing is written to disk.

.PARAMETER Format
    Output file format. CSV is the flat table, JSON carries the export envelope that the
    matching import script validates, HTML is a styled table for sharing.

.EXAMPLE
    PS> ./Export-EsxCoredumpAndLogConfig.ps1 -Server vcenter.example.local -Credential $cred -NonCompliantOnly

    Lists the hosts that would lose their logs on the next reboot.

.NOTES
    Author        : Sampath
    Product       : ESXi (VCF 5.x)
    Target        : VMware Cloud Foundation 5.x
    Modules       : VMware.VimAutomation.Core
    Behaviour     : Read-only. Collects data and optionally writes it to disk.
    Standalone    : Yes. This script does not dot-source or import any other file
                    in this repository and can be copied out on its own.
#>

#Requires -Version 5.1
#Requires -Modules VMware.VimAutomation.Core

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Server,
    [Parameter(Mandatory)] [System.Management.Automation.PSCredential]$Credential,
    [Parameter()] [string[]]$Cluster,
    [Parameter()] [switch]$NonCompliantOnly,
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
    Schema        = 'esx.coredump-log'
    SchemaVersion = '1.0'
    Product       = 'esx'
    VcfVersion    = '5.x'
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

    $hostFilter = @{}
    if ($Cluster) { $hostFilter['Location'] = Get-Cluster -Name $Cluster }
    $vmHosts = Get-VMHost @hostFilter
    Write-Verbose ("Reading dump and log configuration from {0} host(s)." -f @($vmHosts).Count)

    foreach ($vmHost in $vmHosts) {
        if ($vmHost.ConnectionState -ne 'Connected') { continue }

        $configuredScratch = (Get-AdvancedSetting -Entity $vmHost -Name 'ScratchConfig.ConfiguredScratchLocation' -ErrorAction SilentlyContinue).Value
        $currentScratch = (Get-AdvancedSetting -Entity $vmHost -Name 'ScratchConfig.CurrentScratchLocation' -ErrorAction SilentlyContinue).Value
        $logDir = (Get-AdvancedSetting -Entity $vmHost -Name 'Syslog.global.logDir' -ErrorAction SilentlyContinue).Value
        $logDirUnique = (Get-AdvancedSetting -Entity $vmHost -Name 'Syslog.global.logDirUnique' -ErrorAction SilentlyContinue).Value
        $logHost = (Get-AdvancedSetting -Entity $vmHost -Name 'Syslog.global.logHost' -ErrorAction SilentlyContinue).Value

        $dumpPartition = ''
        $netDumpEnabled = $null
        $netDumpServer = ''
        try {
            $esxcli = Get-EsxCli -VMHost $vmHost -V2 -ErrorAction Stop
            $partition = $esxcli.system.coredump.partition.get.Invoke()
            $dumpPartition = $partition.Active

            $network = $esxcli.system.coredump.network.get.Invoke()
            $netDumpEnabled = [bool]$network.Enabled
            $netDumpServer = $network.NetworkServerIP
        }
        catch {
            Write-Verbose "Could not read coredump configuration on '$($vmHost.Name)': $($_.Exception.Message)"
        }

        $scratchPersistent = $currentScratch -and ($currentScratch -notlike '/tmp*') -and ($currentScratch -notlike '*scratch*ramdisk*')
        $logPersistent = $logDir -and ($logDir -notlike '[]*') -and ($logDir -notlike '/scratch/log*' -or $scratchPersistent)
        $dumpConfigured = [bool]$dumpPartition -or $netDumpEnabled

        $compliant = [bool]($scratchPersistent -and $logPersistent -and $dumpConfigured)
        if ($NonCompliantOnly -and $compliant) { continue }

        $records += [pscustomobject]@{
            VMHost                  = $vmHost.Name
            Cluster                 = [string]$vmHost.Parent
            ConfiguredScratch       = $configuredScratch
            CurrentScratch          = $currentScratch
            ScratchPersistent       = $scratchPersistent
            SyslogLogDir            = $logDir
            SyslogLogDirUnique      = $logDirUnique
            SyslogRemoteHost        = $logHost
            LogPersistent           = $logPersistent
            CoredumpPartition       = $dumpPartition
            NetworkCoredumpEnabled  = $netDumpEnabled
            NetworkCoredumpServer   = $netDumpServer
            Compliant               = $compliant
        }
    }

    $records = @($records | Sort-Object Compliant, Cluster, VMHost)
    Write-Verbose ("Collected {0} host row(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    if ($connection) { Disconnect-VIServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
