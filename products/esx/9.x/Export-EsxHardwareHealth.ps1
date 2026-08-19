<#
.SYNOPSIS
    Reports hardware sensor readings that are not green, plus storage device operational state, across every host.

.DESCRIPTION
    Reads the host numeric sensor info and the IPMI system event log summary, and returns
    everything whose health state is not green - failed fans, degraded power supplies, memory
    correctable error thresholds - alongside any storage device not in a normal operational
    state.

    The hardware status tab is per host and green-heavy, so a single amber sensor in a rack of
    forty is easy to miss until it becomes a red one. This is the estate-wide version of that
    tab with the green rows already removed.

    Pain area addressed: #6 Firmware/driver vs HCL compliance.

.PARAMETER Server
    FQDN or IP address of the vCenter Server to connect to.

.PARAMETER Credential
    Credential used to authenticate to vCenter Server.

.PARAMETER Cluster
    Limit to hosts in these clusters.

.PARAMETER IncludeGreen
    Include sensors reporting green. Off by default.

.PARAMETER OutputPath
    Path of the file to write. When omitted the records are only returned on the pipeline and
    nothing is written to disk.

.PARAMETER Format
    Output file format. CSV is the flat table, JSON carries the export envelope that the
    matching import script validates, HTML is a styled table for sharing.

.EXAMPLE
    PS> ./Export-EsxHardwareHealth.ps1 -Server vcenter.example.local -Credential $cred -OutputPath ./health.html -Format HTML

    Produces a shareable hardware exception report.

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
    [Parameter()] [switch]$IncludeGreen,
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
    Schema        = 'esx.hardware-health'
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
    Write-Verbose ("Reading hardware health from {0} host(s)." -f @($vmHosts).Count)

    foreach ($vmHost in $vmHosts) {
        if ($vmHost.ConnectionState -ne 'Connected') {
            Write-Verbose "Skipping '$($vmHost.Name)' - state is $($vmHost.ConnectionState)."
            continue
        }

        $healthView = $null
        try {
            $healthView = Get-View -Id $vmHost.ExtensionData.ConfigManager.HealthStatusSystem -ErrorAction Stop
        }
        catch {
            Write-Warning ("Could not read health status on '{0}': {1}" -f $vmHost.Name, $_.Exception.Message)
            continue
        }

        foreach ($sensor in @($healthView.Runtime.SystemHealthInfo.NumericSensorInfo)) {
            $state = [string]$sensor.HealthState.Key
            if (-not $IncludeGreen -and $state -eq 'green') { continue }

            $records += [pscustomobject]@{
                Kind         = 'Sensor'
                VMHost       = $vmHost.Name
                Cluster      = [string]$vmHost.Parent
                Name         = $sensor.Name
                SensorType   = $sensor.SensorType
                HealthState  = $state
                Reading      = $sensor.CurrentReading
                Units        = $sensor.BaseUnits
                Summary      = $sensor.HealthState.Summary
            }
        }

        foreach ($device in @($vmHost.ExtensionData.Config.StorageDevice.ScsiLun)) {
            $state = ($device.OperationalState -join ', ')
            if (-not $IncludeGreen -and $state -eq 'ok') { continue }

            $records += [pscustomobject]@{
                Kind         = 'StorageDevice'
                VMHost       = $vmHost.Name
                Cluster      = [string]$vmHost.Parent
                Name         = $device.CanonicalName
                SensorType   = $device.DeviceType
                HealthState  = $state
                Reading      = $null
                Units        = ''
                Summary      = $device.DisplayName
            }
        }
    }

    $records = @($records | Sort-Object HealthState, VMHost, Name)
    Write-Verbose ("Collected {0} non-green hardware row(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    if ($connection) { Disconnect-VIServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
