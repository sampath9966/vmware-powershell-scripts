<#
.SYNOPSIS
    Exports every host service with its running state and startup policy, plus enabled firewall rules and their allowed IP ranges.

.DESCRIPTION
    Two views of the host security posture in one file: which services are running and whether
    they start with the host, and which firewall rulesets are enabled along with the IP ranges
    each one accepts - including whether it is open to all.

    'AllIP is true on this ruleset' is a finding auditors ask for and there is no view that
    lists it across hosts. Filter the output to AllowedAll -eq $true and you have the answer.

    Pain area addressed: #9 Config drift (NTP/DNS/syslog/lockdown).

.PARAMETER Server
    FQDN or IP address of the vCenter Server to connect to.

.PARAMETER Credential
    Credential used to authenticate to vCenter Server.

.PARAMETER Cluster
    Limit to hosts in these clusters.

.PARAMETER EnabledRuleOnly
    Return only firewall rules that are currently enabled.

.PARAMETER OutputPath
    Path of the file to write. When omitted the records are only returned on the pipeline and
    nothing is written to disk.

.PARAMETER Format
    Output file format. CSV is the flat table, JSON carries the export envelope that the
    matching import script validates, HTML is a styled table for sharing.

.EXAMPLE
    PS> ./Export-EsxServiceAndFirewall.ps1 -Server vcenter.example.local -Credential $cred | Where-Object { $_.Kind -eq 'Firewall' -and $_.AllowedAll }

    Lists every firewall exception that is open to any source address.

.NOTES
    Author        : Sampath
    Product       : ESX (VCF 9.x)
    Target        : VMware Cloud Foundation 9.x
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
    [Parameter()] [switch]$EnabledRuleOnly,
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
    Schema        = 'esx.service-firewall'
    SchemaVersion = '1.0'
    Product       = 'esx'
    VcfVersion    = '9.x'
    Server        = $Server
}

$connection = $null
try {
    $connection = Connect-VIServer -Server $Server -Credential $Credential -ErrorAction Stop
    Write-Verbose "Connected to vCenter Server $($connection.Name) (version $($connection.Version))"

    $records = @()

    $hostFilter = @{}
    if ($Cluster) { $hostFilter['Location'] = Get-Cluster -Name $Cluster }
    $vmHosts = Get-VMHost @hostFilter
    Write-Verbose ("Reading services and firewall rules from {0} host(s)." -f @($vmHosts).Count)

    foreach ($vmHost in $vmHosts) {
        foreach ($service in (Get-VMHostService -VMHost $vmHost -ErrorAction SilentlyContinue)) {
            $records += [pscustomobject]@{
                Kind         = 'Service'
                VMHost       = $vmHost.Name
                Cluster      = [string]$vmHost.Parent
                Name         = $service.Key
                Label        = $service.Label
                Running      = $service.Running
                Policy       = [string]$service.Policy
                Enabled      = $null
                AllowedAll   = $null
                AllowedIP    = ''
                Required     = $null
            }
        }

        foreach ($rule in (Get-VMHostFirewallException -VMHost $vmHost -ErrorAction SilentlyContinue)) {
            if ($EnabledRuleOnly -and -not $rule.Enabled) { continue }

            $allowedAll = [bool]$rule.ExtensionData.AllowedHosts.AllIP
            $ranges = @()
            foreach ($ip in @($rule.ExtensionData.AllowedHosts.IpAddress)) { $ranges += $ip }
            foreach ($net in @($rule.ExtensionData.AllowedHosts.IpNetwork)) {
                $ranges += ('{0}/{1}' -f $net.Network, $net.PrefixLength)
            }

            $records += [pscustomobject]@{
                Kind         = 'Firewall'
                VMHost       = $vmHost.Name
                Cluster      = [string]$vmHost.Parent
                Name         = $rule.Name
                Label        = $rule.ExtensionData.Key
                Running      = $null
                Policy       = ''
                Enabled      = $rule.Enabled
                AllowedAll   = $allowedAll
                AllowedIP    = ($ranges -join '; ')
                Required     = $rule.ExtensionData.Required
            }
        }
    }

    $records = @($records | Sort-Object Kind, Name, VMHost)
    Write-Verbose ("Collected {0} service and firewall row(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    if ($connection) { Disconnect-VIServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
