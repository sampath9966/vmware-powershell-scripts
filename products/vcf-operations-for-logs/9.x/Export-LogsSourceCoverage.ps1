<#
.SYNOPSIS
    Lists every log source with the time of its last event, and flags sources that have gone silent.

.DESCRIPTION
    Reads the host list the platform maintains and returns each source with its last received
    event time, event count and how many minutes it has been quiet - then buckets each one as
    Active, Quiet or Silent against the threshold you set.

    Supply -ExpectedSource with the hosts that should be forwarding and the script also reports
    the ones that are missing entirely, which is the gap no log platform can see: a host that
    never sent anything does not exist as far as it is concerned.

    Pain area addressed: #9 Config drift (NTP/DNS/syslog/lockdown); #15 Protection gaps.

.PARAMETER Server
    FQDN or IP address of the VCF Operations for Logs node.

.PARAMETER Credential
    Credential used to authenticate to the Logs API.

.PARAMETER QuietMinutes
    Minutes without an event before a source is treated as quiet. Defaults to 60.

.PARAMETER SilentMinutes
    Minutes without an event before a source is treated as silent. Defaults to 1440.

.PARAMETER ExpectedSource
    Hostnames that should be forwarding. Any of these with no source record at all is reported
    as Missing.

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
    PS> ./Export-LogsSourceCoverage.ps1 -Server logs.example.local -Credential $cred | Where-Object Verdict -ne 'Active'

    Lists every source that has stopped sending.

.EXAMPLE
    PS> $esx = (Get-VMHost).Name; ./Export-LogsSourceCoverage.ps1 -Server logs.example.local -Credential $cred -ExpectedSource $esx

    Checks every ESX host in vCenter against what is actually forwarding.

.NOTES
    Author        : Sampath
    Product       : VCF Operations for logs (VCF 9.x)
    Target        : VMware Cloud Foundation 9.x
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
    [Parameter()] [int]$QuietMinutes = 60,
    [Parameter()] [int]$SilentMinutes = 1440,
    [Parameter()] [string[]]$ExpectedSource,
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
    Schema        = 'logs.source-coverage'
    SchemaVersion = '1.0'
    Product       = 'vcf-operations-for-logs'
    VcfVersion    = '9.x'
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

    $response = Invoke-RestMethod @restCommon -Method Get -Uri "$baseUri/api/v2/hosts" -Headers $headers
    $sources = @($response.hosts)
    Write-Verbose ("The platform reports {0} log source(s)." -f $sources.Count)

    $seen = @{}

    foreach ($source in $sources) {
        $lastReceived = $null
        if ($source.lastReceived) {
            try { $lastReceived = [datetimeoffset]::FromUnixTimeMilliseconds([int64]$source.lastReceived).UtcDateTime }
            catch { $lastReceived = $null }
        }

        $quietMinutes = $null
        if ($lastReceived) { $quietMinutes = [int][math]::Floor(((Get-Date).ToUniversalTime() - $lastReceived).TotalMinutes) }

        $verdict = if ($null -eq $quietMinutes) { 'Unknown' }
                   elseif ($quietMinutes -ge $SilentMinutes) { 'Silent' }
                   elseif ($quietMinutes -ge $QuietMinutes) { 'Quiet' }
                   else { 'Active' }

        $seen[$source.hostname] = $true

        $records += [pscustomobject]@{
            Source       = $source.hostname
            LastReceived = if ($lastReceived) { $lastReceived.ToString('u') } else { '' }
            QuietMinutes = $quietMinutes
            EventCount   = $source.eventCount
            Verdict      = $verdict
        }
    }

    foreach ($expected in @($ExpectedSource)) {
        if (-not $expected) { continue }
        if ($seen.ContainsKey($expected)) { continue }

        $records += [pscustomobject]@{
            Source       = $expected
            LastReceived = ''
            QuietMinutes = $null
            EventCount   = 0
            Verdict      = 'Missing'
        }
    }

    $records = @($records | Sort-Object Verdict, Source)
    Write-Verbose ("Collected {0} source record(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    $headers = $null
}
