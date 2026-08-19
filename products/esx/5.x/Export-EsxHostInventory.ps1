<#
.SYNOPSIS
    Collects build, hardware, BIOS and per-adapter driver and firmware versions for every host.

.DESCRIPTION
    One row per host with the ESX build and image profile, hardware vendor and model, BIOS
    version and date, service tag, CPU and memory, and - when -IncludeAdapter is used - the
    driver name, driver version and firmware version of every storage and network adapter,
    pulled from esxcli.

    This is the table an HCL check needs and the one nobody has: the UI shows the model but not
    the firmware, and esxcli gives the firmware one host at a time. Getting it into a
    spreadsheet by hand across a rack is a morning's work.

    Pain area addressed: #6 Firmware/driver vs HCL compliance; #3 BOM / version drift per
    domain.

.PARAMETER Server
    FQDN or IP address of the vCenter Server to connect to.

.PARAMETER Credential
    Credential used to authenticate to vCenter Server.

.PARAMETER Cluster
    Limit to hosts in these clusters.

.PARAMETER IncludeAdapter
    Add one row per storage and network adapter with its driver and firmware version. Slower -
    one esxcli round trip per host.

.PARAMETER ConnectedOnly
    Skip hosts that are not in a connected state.

.PARAMETER OutputPath
    Path of the file to write. When omitted the records are only returned on the pipeline and
    nothing is written to disk.

.PARAMETER Format
    Output file format. CSV is the flat table, JSON carries the export envelope that the
    matching import script validates, HTML is a styled table for sharing.

.EXAMPLE
    PS> ./Export-EsxHostInventory.ps1 -Server vcenter.example.local -Credential $cred -IncludeAdapter -OutputPath ./hosts.csv

    Builds the full driver and firmware table for an HCL review.

.EXAMPLE
    PS> ./Export-EsxHostInventory.ps1 -Server vcenter.example.local -Credential $cred | Group-Object Build

    Shows how many distinct builds are running - the fastest patch-drift check there is.

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
    [Parameter()] [switch]$IncludeAdapter,
    [Parameter()] [switch]$ConnectedOnly,
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
    Schema        = 'esx.host-inventory'
    SchemaVersion = '1.0'
    Product       = 'esx'
    VcfVersion    = '5.x'
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
    Write-Verbose ("Found {0} host(s)." -f @($vmHosts).Count)

    foreach ($vmHost in $vmHosts) {
        if ($ConnectedOnly -and $vmHost.ConnectionState -ne 'Connected') {
            Write-Verbose "Skipping '$($vmHost.Name)' - state is $($vmHost.ConnectionState)."
            continue
        }

        $hardware = $vmHost.ExtensionData.Hardware
        $bios = $hardware.BiosInfo
        $serial = ($hardware.SystemInfo.OtherIdentifyingInfo |
            Where-Object { $_.IdentifierType.Key -eq 'ServiceTag' } | Select-Object -First 1).IdentifierValue

        $records += [pscustomobject]@{
            Scope           = 'Host'
            VMHost          = $vmHost.Name
            Cluster         = [string]$vmHost.Parent
            ConnectionState = [string]$vmHost.ConnectionState
            PowerState      = [string]$vmHost.PowerState
            Version         = $vmHost.Version
            Build           = $vmHost.Build
            Vendor          = $hardware.SystemInfo.Vendor
            Model           = $hardware.SystemInfo.Model
            ServiceTag      = $serial
            BiosVersion     = $bios.BiosVersion
            BiosReleaseDate = $bios.ReleaseDate
            CpuModel        = $hardware.CpuPkg[0].Description
            CpuSockets      = $hardware.CpuInfo.NumCpuPackages
            CpuCores        = $hardware.CpuInfo.NumCpuCores
            MemoryGB        = [math]::Round($vmHost.MemoryTotalGB, 1)
            Device          = ''
            DeviceClass     = ''
            Driver          = ''
            DriverVersion   = ''
            FirmwareVersion = ''
        }

        if (-not $IncludeAdapter) { continue }
        if ($vmHost.ConnectionState -ne 'Connected') { continue }

        try {
            $esxcli = Get-EsxCli -VMHost $vmHost -V2 -ErrorAction Stop

            $driverByDevice = @{}
            foreach ($nic in $esxcli.network.nic.list.Invoke()) {
                $driverByDevice[$nic.Name] = @{ Driver = $nic.Driver; Description = $nic.Description; Class = 'Network' }
            }
            foreach ($hba in $esxcli.storage.core.adapter.list.Invoke()) {
                $driverByDevice[$hba.HBAName] = @{ Driver = $hba.Driver; Description = $hba.Description; Class = 'Storage' }
            }

            foreach ($device in $driverByDevice.Keys) {
                $info = $driverByDevice[$device]

                $driverVersion = ''
                $firmwareVersion = ''
                try {
                    $esxcliArgs = $esxcli.system.module.get.CreateArgs()
                    $esxcliArgs.module = $info.Driver
                    $module = $esxcli.system.module.get.Invoke($esxcliArgs)
                    $driverVersion = $module.Version
                }
                catch { Write-Verbose "No module detail for driver '$($info.Driver)' on $($vmHost.Name)." }

                try {
                    if ($info.Class -eq 'Network') {
                        $esxcliArgs = $esxcli.network.nic.get.CreateArgs()
                        $esxcliArgs.nicname = $device
                        $firmwareVersion = $esxcli.network.nic.get.Invoke($esxcliArgs).DriverInfo.FirmwareVersion
                    }
                }
                catch { Write-Verbose "No firmware detail for '$device' on $($vmHost.Name)." }

                $records += [pscustomobject]@{
                    Scope           = 'Adapter'
                    VMHost          = $vmHost.Name
                    Cluster         = [string]$vmHost.Parent
                    ConnectionState = [string]$vmHost.ConnectionState
                    PowerState      = ''
                    Version         = $vmHost.Version
                    Build           = $vmHost.Build
                    Vendor          = $hardware.SystemInfo.Vendor
                    Model           = $hardware.SystemInfo.Model
                    ServiceTag      = $serial
                    BiosVersion     = $bios.BiosVersion
                    BiosReleaseDate = ''
                    CpuModel        = ''
                    CpuSockets      = $null
                    CpuCores        = $null
                    MemoryGB        = $null
                    Device          = $device
                    DeviceClass     = $info.Class
                    Driver          = $info.Driver
                    DriverVersion   = $driverVersion
                    FirmwareVersion = $firmwareVersion
                }
            }
        }
        catch {
            Write-Warning ("Could not read esxcli on '{0}': {1}" -f $vmHost.Name, $_.Exception.Message)
        }
    }

    $records = @($records | Sort-Object Cluster, VMHost, Scope, Device)
    Write-Verbose ("Collected {0} row(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    if ($connection) { Disconnect-VIServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
