<#
.SYNOPSIS
    Lists the HCX interconnect appliances with their version, deployment state and tunnel status.

.DESCRIPTION
    Returns each deployed appliance - interconnect, network extension, WAN optimiser - with the
    service mesh it belongs to, its version, current state and tunnel status.

    An appliance a version behind the manager, or with a tunnel down, explains most 'the
    migration is stuck' tickets and is several clicks away in the UI.

    Pain area addressed: #9 Config drift (NTP/DNS/syslog/lockdown).

.PARAMETER Server
    FQDN or IP address of the HCX Manager at the source site.

.PARAMETER Credential
    Credential used to authenticate to HCX Manager.

.PARAMETER UnhealthyOnly
    Return only appliances that are not fully up.

.PARAMETER OutputPath
    Path of the file to write. When omitted the records are only returned on the pipeline and
    nothing is written to disk.

.PARAMETER Format
    Output file format. CSV is the flat table, JSON carries the export envelope that the
    matching import script validates, HTML is a styled table for sharing.

.EXAMPLE
    PS> ./Export-HcxApplianceHealth.ps1 -Server hcx.example.local -Credential $cred -UnhealthyOnly

    Lists appliances that are degraded or have a tunnel down.

.NOTES
    Author        : Sampath
    Product       : HCX (VCF 5.x)
    Target        : VMware Cloud Foundation 5.x
    Modules       : VMware.VimAutomation.Hcx
    Behaviour     : Read-only. Collects data and optionally writes it to disk.
    Standalone    : Yes. This script does not dot-source or import any other file
                    in this repository and can be copied out on its own.
#>

#Requires -Version 5.1
#Requires -Modules VMware.VimAutomation.Hcx

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Server,
    [Parameter(Mandatory)] [System.Management.Automation.PSCredential]$Credential,
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
    Schema        = 'hcx.appliance-health'
    SchemaVersion = '1.0'
    Product       = 'vcf-operations-hcx'
    VcfVersion    = '5.x'
    Server        = $Server
}

$connection = $null
try {
    $connection = Connect-HCXServer -Server $Server -Credential $Credential -ErrorAction Stop
    Write-Verbose "Connected to HCX Manager $($connection.Server)"

    $records = @()

    $appliances = @(Get-HCXAppliance -ErrorAction SilentlyContinue)
    Write-Verbose ("HCX reports {0} appliance(s)." -f $appliances.Count)

    foreach ($appliance in $appliances) {
        $state = [string]$appliance.State
        $tunnelStatus = [string]$appliance.TunnelStatus
        $healthy = ($state -in @('DEPLOYED', 'RUNNING', 'UP')) -and ($tunnelStatus -in @('UP', '', 'TUNNEL_UP'))

        if ($UnhealthyOnly -and $healthy) { continue }

        $records += [pscustomobject]@{
            Name         = $appliance.Name
            ApplianceId  = $appliance.Id
            Type         = [string]$appliance.Type
            ServiceMesh  = [string]$appliance.ServiceMesh
            Version      = $appliance.Version
            State        = $state
            TunnelStatus = $tunnelStatus
            Healthy      = $healthy
            Message      = ($appliance.StatusMessage -replace '\s+', ' ')
        }
    }

    $records = @($records | Sort-Object Healthy, Type, Name)
    Write-Verbose ("Collected {0} appliance record(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    if ($connection) { Disconnect-HCXServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
