<#
.SYNOPSIS
    Lists the configured log forwarding destinations with protocol, filter and current forwarding state.

.DESCRIPTION
    Returns each forwarder with its destination host and port, protocol, any filter applied to
    what it sends, whether SSL is on, and the current state and error message where the platform
    records one.

    Forwarding to a SIEM is usually a compliance obligation, and a forwarder that has been
    failing for a fortnight looks exactly like one that is working until someone checks.

    Pain area addressed: #9 Config drift (NTP/DNS/syslog/lockdown); #16 Config portability
    between environments.

.PARAMETER Server
    FQDN or IP address of the VCF Operations for Logs node.

.PARAMETER Credential
    Credential used to authenticate to the Logs API.

.PARAMETER FailedOnly
    Return only forwarders that are not currently healthy.

.PARAMETER IgnoreInvalidCertificate
    Accept an untrusted or self-signed certificate on the target endpoint. Use only in lab
    environments.

.PARAMETER OutputPath
    Path of the file to write. When omitted the records are only returned on the pipeline and
    nothing is written to disk.

.PARAMETER Format
    Output file format. CSV is the flat table, JSON carries the export envelope that the
    matching import script validates, HTML is a styled table for sharing.

.EXAMPLE
    PS> ./Export-LogsForwarder.ps1 -Server logs.example.local -Credential $cred -FailedOnly

    Lists forwarders that are not delivering.

.NOTES
    Author        : Sampath
    Product       : Aria Operations for Logs (VCF 5.x)
    Target        : VMware Cloud Foundation 5.x
    Modules       : None (uses Invoke-RestMethod)
    Behaviour     : Read-only. Collects data and optionally writes it to disk.
    Standalone    : Yes. This script does not dot-source or import any other file
                    in this repository and can be copied out on its own.
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Server,
    [Parameter(Mandatory)] [System.Management.Automation.PSCredential]$Credential,
    [Parameter()] [switch]$FailedOnly,
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
    Schema        = 'logs.forwarder'
    SchemaVersion = '1.0'
    Product       = 'vcf-operations-for-logs'
    VcfVersion    = '5.x'
    Server        = $Server
}

$headers = $null
try {
    $restCommon = @{ ContentType = 'application/json' }

    if ($PSVersionTable.PSVersion.Major -lt 6) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    }

    if ($IgnoreInvalidCertificate) {
        if ($PSVersionTable.PSVersion.Major -ge 6) {
            $restCommon['SkipCertificateCheck'] = $true
        }
        else {
            Write-Warning 'Certificate validation is disabled for this session. Use this only in lab environments.'
            [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        }
    }

    $baseUri = "https://$Server"
    $authBody = @{ provider = 'Local'; username = $Credential.UserName; password = $Credential.GetNetworkCredential().Password } | ConvertTo-Json
    $authResponse = Invoke-RestMethod @restCommon -Method Post -Uri "$baseUri/api/v2/sessions" -Body $authBody
    $headers = @{ Accept = 'application/json'; Authorization = "Bearer $($authResponse.sessionId)" }
    Write-Verbose "Acquired a Logs API session from $Server"

    $records = @()

    $response = Invoke-RestMethod @restCommon -Method Get -Uri "$baseUri/api/v2/forwarders" -Headers $headers
    $forwarders = @($response.forwarders)
    Write-Verbose ("The platform reports {0} forwarder(s)." -f $forwarders.Count)

    foreach ($forwarder in $forwarders) {
        $healthy = ($forwarder.state -eq 'OK') -or ($forwarder.state -eq 'ACTIVE')
        if ($FailedOnly -and $healthy) { continue }

        $records += [pscustomobject]@{
            Name        = $forwarder.name
            Destination = $forwarder.host
            Port        = $forwarder.port
            Protocol    = $forwarder.protocol
            SslEnabled  = $forwarder.sslEnabled
            Filter      = ($forwarder.filter -replace '\s+', ' ')
            Tags        = (@($forwarder.tags.PSObject.Properties.Name) -join '; ')
            State       = $forwarder.state
            Healthy     = $healthy
            Message     = ($forwarder.errorMessage -replace '\s+', ' ')
        }
    }

    $records = @($records | Sort-Object Healthy, Name)
    Write-Verbose ("Collected {0} forwarder record(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    $headers = $null
}
