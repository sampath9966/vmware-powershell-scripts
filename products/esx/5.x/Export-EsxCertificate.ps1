<#
.SYNOPSIS
    Reports the machine certificate of every host with its issuer, expiry and days remaining.

.DESCRIPTION
    Reads the SSL certificate each host presents and returns subject, issuer, validity window,
    days remaining, key size and signature algorithm, plus a Status column bucketing them into
    Expired, Critical, Warning and Ok.

    Host certificates are the ones people forget, because they renew automatically until the day
    they do not - and a host with an expired certificate disconnects from vCenter. This is the
    estate-wide expiry list.

    Pain area addressed: #1 Certificate expiry across the stack.

.PARAMETER Server
    FQDN or IP address of the vCenter Server to connect to.

.PARAMETER Credential
    Credential used to authenticate to vCenter Server.

.PARAMETER Cluster
    Limit to hosts in these clusters.

.PARAMETER ExpiringInDays
    Return only certificates expiring within this many days.

.PARAMETER OutputPath
    Path of the file to write. When omitted the records are only returned on the pipeline and
    nothing is written to disk.

.PARAMETER Format
    Output file format. CSV is the flat table, JSON carries the export envelope that the
    matching import script validates, HTML is a styled table for sharing.

.EXAMPLE
    PS> ./Export-EsxCertificate.ps1 -Server vcenter.example.local -Credential $cred -ExpiringInDays 60

    Lists host certificates expiring in the next two months.

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
    [Parameter()] [int]$ExpiringInDays = 0,
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
    Schema        = 'esx.certificate'
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
    Write-Verbose ("Reading certificates from {0} host(s)." -f @($vmHosts).Count)

    foreach ($vmHost in $vmHosts) {
        if ($vmHost.ConnectionState -ne 'Connected') { continue }

        try {
            $certificateManager = Get-View -Id $vmHost.ExtensionData.ConfigManager.CertificateManager -ErrorAction Stop
            $info = $certificateManager.CertificateInfo

            $notAfter = $null
            if ($info.NotAfter) { $notAfter = [datetime]$info.NotAfter }

            $daysRemaining = $null
            if ($notAfter) { $daysRemaining = [int][math]::Floor(($notAfter - (Get-Date)).TotalDays) }

            if ($ExpiringInDays -gt 0) {
                if ($null -eq $daysRemaining -or $daysRemaining -gt $ExpiringInDays) { continue }
            }

            $status = 'Unknown'
            if ($null -ne $daysRemaining) {
                $status = if ($daysRemaining -lt 0) { 'Expired' }
                          elseif ($daysRemaining -le 30) { 'Critical' }
                          elseif ($daysRemaining -le 90) { 'Warning' }
                          else { 'Ok' }
            }

            $records += [pscustomobject]@{
                VMHost        = $vmHost.Name
                Cluster       = [string]$vmHost.Parent
                Subject       = $info.Subject
                Issuer        = $info.Issuer
                NotBefore     = $info.NotBefore
                NotAfter      = $info.NotAfter
                DaysRemaining = $daysRemaining
                Status        = $status
            }
        }
        catch {
            Write-Warning ("Could not read the certificate on '{0}': {1}" -f $vmHost.Name, $_.Exception.Message)
        }
    }

    $records = @($records | Sort-Object { if ($null -eq $_.DaysRemaining) { [int]::MaxValue } else { $_.DaysRemaining } })
    Write-Verbose ("Collected {0} certificate record(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    if ($connection) { Disconnect-VIServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
