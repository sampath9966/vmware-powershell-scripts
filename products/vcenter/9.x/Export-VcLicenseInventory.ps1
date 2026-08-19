<#
.SYNOPSIS
    Reports licence keys, what they are assigned to, and the physical core counts a core-based licence is measured against.

.DESCRIPTION
    Pulls the licence manager view - key, edition, total and used capacity, expiry - and joins
    it to the physical inventory it is actually consumed by, so each cluster comes back with its
    socket count, physical core count, and the per-host core spread.

    Core-based licensing turned 'how many licences do we need' into an inventory question with a
    minimum-cores-per-CPU floor, and no single screen answers it. This gives the raw counts the
    calculation needs, per cluster and per host, next to what is currently assigned.

    Pain area addressed: #7 Licensing and core counts.

.PARAMETER Server
    FQDN or IP address of the vCenter Server to connect to.

.PARAMETER Credential
    Credential used to authenticate to vCenter Server.

.PARAMETER IncludeHostDetail
    Add one row per host alongside the per-cluster summary rows.

.PARAMETER OutputPath
    Path of the file to write. When omitted the records are only returned on the pipeline and
    nothing is written to disk.

.PARAMETER Format
    Output file format. CSV is the flat table, JSON carries the export envelope that the
    matching import script validates, HTML is a styled table for sharing.

.EXAMPLE
    PS> ./Export-VcLicenseInventory.ps1 -Server vcenter.example.local -Credential $cred -OutputPath ./licensing.html -Format HTML

    Produces a shareable licensing position for the whole vCenter.

.EXAMPLE
    PS> ./Export-VcLicenseInventory.ps1 -Server vcenter.example.local -Credential $cred | Where-Object Scope -eq 'Cluster' | Measure-Object PhysicalCores -Sum

    Totals physical cores across every cluster.

.NOTES
    Author        : Sampath
    Product       : vCenter (VCF 9.x)
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
    [Parameter()] [switch]$IncludeHostDetail,
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
    Schema        = 'vcenter.license-inventory'
    SchemaVersion = '1.0'
    Product       = 'vcenter'
    VcfVersion    = '9.x'
    Server        = $Server
}

$connection = $null
try {
    $connection = Connect-VIServer -Server $Server -Credential $Credential -ErrorAction Stop
    Write-Verbose "Connected to vCenter Server $($connection.Name) (version $($connection.Version))"

    $records = @()

    $licenseManager = Get-View -Id (Get-View ServiceInstance).Content.LicenseManager
    $assignmentManager = Get-View -Id $licenseManager.LicenseAssignmentManager
    $assignments = @($assignmentManager.QueryAssignedLicenses($null))

    foreach ($license in @($licenseManager.Licenses)) {
        if ($license.LicenseKey -eq '00000-00000-00000-00000-00000') { continue }

        $expiry = ($license.Properties | Where-Object { $_.Key -eq 'expirationDate' }).Value
        $assignedTo = @($assignments | Where-Object { $_.AssignedLicense.LicenseKey -eq $license.LicenseKey }).EntityDisplayName

        $records += [pscustomobject]@{
            Scope         = 'License'
            Name          = $license.Name
            Edition       = $license.EditionKey
            LicenseKey    = ('{0}-XXXXX-XXXXX-XXXXX-{1}' -f $license.LicenseKey.Substring(0, 5), $license.LicenseKey.Substring($license.LicenseKey.Length - 5))
            Total         = $license.Total
            Used          = $license.Used
            CostUnit      = ($license.Properties | Where-Object { $_.Key -eq 'CostUnit' }).Value
            Expiry        = $expiry
            AssignedCount = @($assignedTo).Count
            AssignedTo    = ($assignedTo | Sort-Object) -join '; '
            Sockets       = $null
            PhysicalCores = $null
            Hosts         = $null
        }
    }

    foreach ($cluster in (Get-Cluster)) {
        $clusterHosts = @(Get-VMHost -Location $cluster)
        $sockets = ($clusterHosts | Measure-Object -Property @{ Expression = { $_.ExtensionData.Hardware.CpuInfo.NumCpuPackages } } -Sum).Sum
        $cores = ($clusterHosts | Measure-Object -Property @{ Expression = { $_.ExtensionData.Hardware.CpuInfo.NumCpuCores } } -Sum).Sum

        $records += [pscustomobject]@{
            Scope         = 'Cluster'
            Name          = $cluster.Name
            Edition       = $null
            LicenseKey    = $null
            Total         = $null
            Used          = $null
            CostUnit      = $null
            Expiry        = $null
            AssignedCount = $null
            AssignedTo    = $null
            Sockets       = $sockets
            PhysicalCores = $cores
            Hosts         = $clusterHosts.Count
        }

        if ($IncludeHostDetail) {
            foreach ($vmHost in $clusterHosts) {
                $records += [pscustomobject]@{
                    Scope         = 'Host'
                    Name          = $vmHost.Name
                    Edition       = $vmHost.LicenseKey
                    LicenseKey    = $null
                    Total         = $null
                    Used          = $null
                    CostUnit      = $null
                    Expiry        = $null
                    AssignedCount = $null
                    AssignedTo    = $cluster.Name
                    Sockets       = $vmHost.ExtensionData.Hardware.CpuInfo.NumCpuPackages
                    PhysicalCores = $vmHost.ExtensionData.Hardware.CpuInfo.NumCpuCores
                    Hosts         = 1
                }
            }
        }
    }

    $records = @($records | Sort-Object Scope, Name)
    Write-Verbose ("Collected {0} licensing row(s). Licence keys are masked in the output." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    if ($connection) { Disconnect-VIServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
