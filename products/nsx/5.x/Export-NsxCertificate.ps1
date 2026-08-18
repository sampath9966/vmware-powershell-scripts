<#
.SYNOPSIS
    Lists every certificate held by NSX with its subject, issuer, expiry and what it is used for.

.DESCRIPTION
    Reads the trust management certificate store and returns subject, issuer, validity window,
    days remaining, key size and signature algorithm for every certificate, along with the
    service it is bound to where NSX records one.

    NSX holds more certificates than people expect - the manager cluster, the VIP, edge nodes,
    principal identities - and an expiry on any of them ends badly. This is the single list.

    Pain area addressed: #1 Certificate expiry across the stack.

.PARAMETER Server
    FQDN or IP address of the NSX Manager to connect to.

.PARAMETER Credential
    Credential used to authenticate to NSX Manager.

.PARAMETER ExpiringInDays
    Return only certificates expiring within this many days.

.PARAMETER IncludeSystem
    Include NSX-generated internal certificates. Off by default.

.PARAMETER OutputPath
    Path of the file to write. When omitted the records are only returned on the pipeline and
    nothing is written to disk.

.PARAMETER Format
    Output file format. CSV is the flat table, JSON carries the export envelope that the
    matching import script validates, HTML is a styled table for sharing.

.EXAMPLE
    PS> ./Export-NsxCertificate.ps1 -Server nsx.example.local -Credential $cred -ExpiringInDays 90

    Lists NSX certificates expiring in the next quarter.

.NOTES
    Author        : Sampath
    Product       : NSX-T Data Center (VCF 5.x)
    Target        : VMware Cloud Foundation 5.x
    Modules       : VMware.VimAutomation.Nsxt
    Behaviour     : Read-only. Collects data and optionally writes it to disk.
    Standalone    : Yes. This script does not dot-source or import any other file
                    in this repository and can be copied out on its own.
#>

#Requires -Version 5.1
#Requires -Modules VMware.VimAutomation.Nsxt

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Server,
    [Parameter(Mandatory)] [System.Management.Automation.PSCredential]$Credential,
    [Parameter()] [int]$ExpiringInDays = 0,
    [Parameter()] [switch]$IncludeSystem,
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
    Schema        = 'nsx.certificate'
    SchemaVersion = '1.0'
    Product       = 'nsx'
    VcfVersion    = '5.x'
    Server        = $Server
}

$connection = $null
try {
    $connection = Connect-NsxtServer -Server $Server -Credential $Credential -ErrorAction Stop
    Write-Verbose "Connected to NSX Manager $($connection.Name)"

    $records = @()

    $certificateService = Get-NsxtService -Name 'com.vmware.nsx.trust_management.certificates'
    $certificates = @($certificateService.list().results)
    Write-Verbose ("NSX holds {0} certificate(s)." -f $certificates.Count)

    foreach ($certificate in $certificates) {
        if (-not $IncludeSystem -and $certificate.used_by.Count -eq 0 -and $certificate.display_name -match '^(tomcat|mp-cluster|nsx-)') {
            continue
        }

        $detail = @($certificate.details)[0]

        $notAfter = $null
        if ($detail.not_after) {
            try { $notAfter = [datetimeoffset]::FromUnixTimeMilliseconds([int64]$detail.not_after).UtcDateTime }
            catch { $notAfter = $null }
        }

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
            Name               = $certificate.display_name
            CertificateId      = $certificate.id
            Subject            = $detail.subject
            Issuer             = $detail.issuer
            SerialNumber       = $detail.serial_number
            SignatureAlgorithm = $detail.signature_algorithm
            KeySize            = $detail.public_key_length
            NotBefore          = $detail.not_before
            NotAfter           = if ($notAfter) { $notAfter.ToString('u') } else { '' }
            DaysRemaining      = $daysRemaining
            Status             = $status
            UsedBy             = (@($certificate.used_by).service_types -join '; ')
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
    if ($connection) { Disconnect-NsxtServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
