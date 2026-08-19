<#
.SYNOPSIS
    Exports advanced settings whose value differs from the shipped default, or a named set, across every host.

.DESCRIPTION
    By default this returns only settings that have been changed from their default value -
    which is normally a few dozen rows rather than the several thousand a full dump produces -
    so the output is the set of deliberate changes plus the accidents.

    Use -Name with wildcards to pull a specific family across every host, for example 'Syslog.*'
    or 'UserVars.SuppressShellWarning'. The file feeds Import-EsxAdvancedSetting.ps1.

    Pain area addressed: #9 Config drift (NTP/DNS/syslog/lockdown).

.PARAMETER Server
    FQDN or IP address of the vCenter Server to connect to.

.PARAMETER Credential
    Credential used to authenticate to vCenter Server.

.PARAMETER Cluster
    Limit to hosts in these clusters.

.PARAMETER Name
    Setting names to collect. Wildcards accepted. Omit to collect everything non-default.

.PARAMETER IncludeDefault
    Include settings still at their shipped default value. Produces a very large output.

.PARAMETER OutputPath
    Path of the file to write. When omitted the records are only returned on the pipeline and
    nothing is written to disk.

.PARAMETER Format
    Output file format. CSV is the flat table, JSON carries the export envelope that the
    matching import script validates, HTML is a styled table for sharing.

.EXAMPLE
    PS> ./Export-EsxAdvancedSetting.ps1 -Server vcenter.example.local -Credential $cred -OutputPath ./adv.json -Format JSON

    Captures every non-default advanced setting on every host.

.EXAMPLE
    PS> ./Export-EsxAdvancedSetting.ps1 -Server vcenter.example.local -Credential $cred -Name 'Syslog.*' | Sort-Object Name, VMHost

    Compares the whole syslog family side by side across hosts.

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
    [Parameter()] [string[]]$Name,
    [Parameter()] [switch]$IncludeDefault,
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
    Schema        = 'esx.advanced-setting'
    SchemaVersion = '1.0'
    Product       = 'esx'
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

    $hostFilter = @{}
    if ($Cluster) { $hostFilter['Location'] = Get-Cluster -Name $Cluster }
    $vmHosts = Get-VMHost @hostFilter
    Write-Verbose ("Reading advanced settings from {0} host(s)." -f @($vmHosts).Count)

    foreach ($vmHost in $vmHosts) {
        $settingParams = @{ Entity = $vmHost; ErrorAction = 'SilentlyContinue' }
        if ($Name) { $settingParams['Name'] = $Name }

        foreach ($setting in (Get-AdvancedSetting @settingParams)) {
            $isDefault = ($null -ne $setting.ExtensionData) -and ($setting.Value -eq $setting.ExtensionData.DefaultValue)
            if (-not $IncludeDefault -and $isDefault) { continue }

            $records += [pscustomobject]@{
                VMHost       = $vmHost.Name
                Cluster      = [string]$vmHost.Parent
                Name         = $setting.Name
                Value        = [string]$setting.Value
                DefaultValue = if ($setting.ExtensionData) { [string]$setting.ExtensionData.DefaultValue } else { '' }
                IsDefault    = $isDefault
                Type         = $setting.Type
                Description  = $setting.Description
            }
        }
    }

    $records = @($records | Sort-Object Name, VMHost)
    Write-Verbose ("Collected {0} advanced setting row(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    if ($connection) { Disconnect-VIServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
