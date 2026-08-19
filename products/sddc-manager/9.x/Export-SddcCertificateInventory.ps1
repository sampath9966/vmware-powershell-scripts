<#
.SYNOPSIS
    Collects every resource certificate known to SDDC Manager, with days remaining until expiry.

.DESCRIPTION
    Walks every workload domain and pulls the resource certificates SDDC Manager holds for each
    component - vCenter, ESX hosts, NSX Manager and the SDDC Manager appliance itself - then
    flattens them into one table with the issuer, subject, key size, signature algorithm and the
    number of days left before expiry.

    The SDDC Manager UI shows certificates one domain at a time with no export, which is why
    'when does anything in this environment expire' normally turns into a spreadsheet built by
    hand. Sort the output by DaysRemaining and the answer is the first row.

    Calls GET /v1/domains and GET /v1/domains/{id}/resource-certificates.

    Pain area addressed: #1 Certificate expiry across the stack.

.PARAMETER Server
    FQDN or IP address of the SDDC Manager appliance.

.PARAMETER Credential
    Credential used to authenticate to SDDC Manager (for example administrator@vsphere.local).

.PARAMETER DomainName
    Limit the collection to these workload domain names. Omit to walk every domain.

.PARAMETER ExpiringInDays
    Return only certificates expiring within this many days. Omit to return them all.

.PARAMETER IgnoreInvalidCertificate
    Accept an untrusted or self-signed certificate on the SDDC Manager endpoint. Use only in lab
    environments.

.PARAMETER OutputPath
    Path of the file to write. When omitted the records are only returned on the pipeline and
    nothing is written to disk.

.PARAMETER Format
    Output file format. CSV is the flat table, JSON carries the export envelope that the
    matching import script validates, HTML is a styled table for sharing.

.EXAMPLE
    PS> ./Export-SddcCertificateInventory.ps1 -Server sddc.example.local -Credential (Get-Credential)

    Returns every certificate in the instance on the pipeline, newest expiry last.

.EXAMPLE
    PS> ./Export-SddcCertificateInventory.ps1 -Server sddc.example.local -Credential $cred -ExpiringInDays 90 -OutputPath ./certs.json -Format JSON

    Writes only the certificates expiring in the next 90 days, in the envelope format that
    Invoke-SddcCertificateRenewal.ps1 accepts as input.

.NOTES
    Author        : Sampath
    Product       : SDDC Manager (VCF 9.x)
    Target        : VMware Cloud Foundation 9.x
    Modules       : VMware.Sdk.Vcf.SddcManager
    Behaviour     : Read-only. Collects data and optionally writes it to disk.
    Standalone    : Yes. This script does not dot-source or import any other file
                    in this repository and can be copied out on its own.
#>

#Requires -Version 5.1
#Requires -Modules VMware.Sdk.Vcf.SddcManager

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Server,
    [Parameter(Mandatory)] [System.Management.Automation.PSCredential]$Credential,
    [Parameter()] [string[]]$DomainName,
    [Parameter()] [int]$ExpiringInDays = 0,
    [Parameter()] [switch]$IgnoreInvalidCertificate,
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
    Schema        = 'vcf.sddc.certificate-inventory'
    SchemaVersion = '1.0'
    Product       = 'sddc-manager'
    VcfVersion    = '9.x'
    Server        = $Server
}

$connection = $null
try {
    $connectParams = @{
        Server   = $Server
        User     = $Credential.UserName
        Password = $Credential.GetNetworkCredential().Password
    }
    if ($IgnoreInvalidCertificate) { $connectParams['IgnoreInvalidCertificate'] = $true }
    $connection = Connect-VcfSddcManagerServer @connectParams -ErrorAction Stop
    Write-Verbose "Connected to SDDC Manager $Server"
    # Scope every call in this script to the connection opened above. Without this,
    # PowerCLI cmdlets act on every connected server, which silently mixes inventories
    # when more than one is connected. The hashtable is cloned first because indexing
    # the inherited one would change the caller's session defaults too.
    $PSDefaultParameterValues = $PSDefaultParameterValues.Clone()
    $PSDefaultParameterValues['*:Server'] = $connection

    $records = @()

    $domains = Invoke-VcfGetDomains
    Write-Verbose ("Found {0} workload domain(s)." -f @($domains.Elements).Count)

    foreach ($domain in @($domains.Elements)) {
        if ($DomainName -and $domain.Name -notin $DomainName) {
            Write-Verbose "Skipping domain '$($domain.Name)' - not in -DomainName."
            continue
        }

        Write-Verbose "Reading resource certificates for domain '$($domain.Name)'."
        $certificates = Invoke-VcfGetResourceCertificates -Id $domain.Id

        foreach ($certificate in @($certificates.Elements)) {
            $notAfter = $null
            if ($certificate.NotAfter) {
                try { $notAfter = [datetime]$certificate.NotAfter } catch { $notAfter = $null }
            }

            $daysRemaining = $null
            if ($notAfter) {
                $daysRemaining = [int][math]::Floor(($notAfter - (Get-Date)).TotalDays)
            }

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
                Domain             = $domain.Name
                DomainId           = $domain.Id
                DomainType         = $domain.Type
                ResourceFqdn       = $certificate.ResourceFqdn
                ResourceType       = $certificate.ResourceType
                Subject            = $certificate.Subject
                Issuer             = $certificate.IssuedBy
                SerialNumber       = $certificate.SerialNumber
                SignatureAlgorithm = $certificate.SignatureAlgorithm
                KeySize            = $certificate.KeySize
                NotBefore          = $certificate.NotBefore
                NotAfter           = $certificate.NotAfter
                DaysRemaining      = $daysRemaining
                Status             = $status
            }
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
    if ($connection) { Disconnect-VcfSddcManagerServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
