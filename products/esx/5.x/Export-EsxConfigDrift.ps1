<#
.SYNOPSIS
    Captures the time, name resolution, logging and lockdown configuration of every host and flags what differs from the majority.

.DESCRIPTION
    Reads NTP servers and service state, DNS servers and search domains, syslog target and log
    directory, lockdown mode, SSH and shell service state and their startup policy, then adds a
    Drift column marking any host whose value differs from the most common value in the set.

    The majority-value comparison is the useful part: you rarely have a documented baseline, but
    you almost always want to know which three hosts out of forty disagree with the rest. The
    same file is the baseline Import-EsxConfigBaseline.ps1 applies.

    Pain area addressed: #9 Config drift (NTP/DNS/syslog/lockdown).

.PARAMETER Server
    FQDN or IP address of the vCenter Server to connect to.

.PARAMETER Credential
    Credential used to authenticate to vCenter Server.

.PARAMETER Cluster
    Limit to hosts in these clusters.

.PARAMETER DriftOnly
    Return only hosts that differ from the majority on at least one setting.

.PARAMETER OutputPath
    Path of the file to write. When omitted the records are only returned on the pipeline and
    nothing is written to disk.

.PARAMETER Format
    Output file format. CSV is the flat table, JSON carries the export envelope that the
    matching import script validates, HTML is a styled table for sharing.

.EXAMPLE
    PS> ./Export-EsxConfigDrift.ps1 -Server vcenter.example.local -Credential $cred -DriftOnly

    Shows only the hosts that disagree with the rest of the estate.

.EXAMPLE
    PS> ./Export-EsxConfigDrift.ps1 -Server vcenter.example.local -Credential $cred -OutputPath ./hostconfig.json -Format JSON

    Captures the current state as the baseline for Import-EsxConfigBaseline.ps1.

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
    [Parameter()] [switch]$DriftOnly,
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
    Schema        = 'esx.host-config'
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
    # Scope every call in this script to the connection opened above. Without this,
    # PowerCLI cmdlets act on every connected server, which silently mixes inventories
    # when more than one is connected. The hashtable is cloned first because indexing
    # the inherited one would change the caller's session defaults too.
    $PSDefaultParameterValues = $PSDefaultParameterValues.Clone()
    $PSDefaultParameterValues['*:Server'] = $connection

    $records = @()

    $hostFilter = @{}
    if ($Cluster) { $hostFilter['Location'] = Get-Cluster -Name $Cluster }
    $vmHosts = Get-VMHost @hostFilter
    Write-Verbose ("Reading configuration from {0} host(s)." -f @($vmHosts).Count)

    foreach ($vmHost in $vmHosts) {
        $services = @(Get-VMHostService -VMHost $vmHost -ErrorAction SilentlyContinue)
        $ntpService = $services | Where-Object { $_.Key -eq 'ntpd' }
        $sshService = $services | Where-Object { $_.Key -eq 'TSM-SSH' }
        $shellService = $services | Where-Object { $_.Key -eq 'TSM' }
        $network = Get-VMHostNetwork -VMHost $vmHost -ErrorAction SilentlyContinue

        $syslogHost = (Get-AdvancedSetting -Entity $vmHost -Name 'Syslog.global.logHost' -ErrorAction SilentlyContinue).Value
        $logDir = (Get-AdvancedSetting -Entity $vmHost -Name 'Syslog.global.logDir' -ErrorAction SilentlyContinue).Value

        $records += [pscustomobject]@{
            VMHost           = $vmHost.Name
            Cluster          = [string]$vmHost.Parent
            NtpServer        = ((Get-VMHostNtpServer -VMHost $vmHost -ErrorAction SilentlyContinue) -join '; ')
            NtpRunning       = if ($ntpService) { $ntpService.Running } else { $null }
            NtpPolicy        = if ($ntpService) { [string]$ntpService.Policy } else { '' }
            DnsServer        = if ($network) { ($network.DnsAddress -join '; ') } else { '' }
            SearchDomain     = if ($network) { ($network.SearchDomain -join '; ') } else { '' }
            DomainName       = if ($network) { $network.DomainName } else { '' }
            SyslogHost       = $syslogHost
            SyslogLogDir     = $logDir
            LockdownMode     = [string]$vmHost.ExtensionData.Config.LockdownMode
            SshRunning       = if ($sshService) { $sshService.Running } else { $null }
            SshPolicy        = if ($sshService) { [string]$sshService.Policy } else { '' }
            ShellRunning     = if ($shellService) { $shellService.Running } else { $null }
            ShellPolicy      = if ($shellService) { [string]$shellService.Policy } else { '' }
            Drift            = ''
        }
    }

    $compared = @('NtpServer', 'NtpPolicy', 'DnsServer', 'SearchDomain', 'SyslogHost', 'SyslogLogDir', 'LockdownMode', 'SshPolicy', 'ShellPolicy')
    $majority = @{}
    foreach ($property in $compared) {
        $top = $records | Group-Object -Property $property | Sort-Object Count -Descending | Select-Object -First 1
        if ($top) { $majority[$property] = $top.Name }
    }

    foreach ($record in $records) {
        $differences = @()
        foreach ($property in $compared) {
            if ([string]$record.$property -ne [string]$majority[$property]) { $differences += $property }
        }
        $record.Drift = $differences -join '; '
    }

    if ($DriftOnly) { $records = @($records | Where-Object { $_.Drift }) }

    $records = @($records | Sort-Object Cluster, VMHost)
    Write-Verbose ("Collected {0} host record(s); majority values used as the implicit baseline." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    if ($connection) { Disconnect-VIServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
