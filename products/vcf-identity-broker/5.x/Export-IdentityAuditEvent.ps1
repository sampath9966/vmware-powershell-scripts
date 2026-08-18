<#
.SYNOPSIS
    Extracts audit events for a window - logins, failures and administrative changes - as a flat table.

.DESCRIPTION
    Returns each audit event with its timestamp, type, the actor, the object acted on, the
    source IP and the outcome, over the window you choose.

    Failed login clustering is the signal here: filter to failures and group by actor or source
    IP and either a locked-out user or something less pleasant becomes obvious immediately.

    Pain area addressed: #13 Alarm noise and audit-trail extraction.

.PARAMETER Server
    FQDN or IP address of the VCF Identity Broker appliance.

.PARAMETER Credential
    Credential used to authenticate to the Identity Broker API.

.PARAMETER Days
    How many days of audit history to collect. Defaults to 7.

.PARAMETER EventType
    Limit to these event types, for example LOGIN or LOGIN_FAILED.

.PARAMETER FailuresOnly
    Return only events whose outcome was a failure.

.PARAMETER PageSize
    How many events to request per call. Defaults to 500.

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
    PS> ./Export-IdentityAuditEvent.ps1 -Server idb.example.local -Credential $cred -FailuresOnly -Days 1 | Group-Object Actor | Sort-Object Count -Descending

    Finds the accounts producing the most login failures today.

.NOTES
    Author        : Sampath
    Product       : Workspace ONE Access (VCF 5.x)
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
    [Parameter()] [int]$Days = 7,
    [Parameter()] [string[]]$EventType,
    [Parameter()] [switch]$FailuresOnly,
    [Parameter()] [int]$PageSize = 500,
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
    Schema        = 'identity.audit-event'
    SchemaVersion = '1.0'
    Product       = 'vcf-identity-broker'
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
    $authBody = @{ username = $Credential.UserName; password = $Credential.GetNetworkCredential().Password; issueToken = $true } | ConvertTo-Json
    $authResponse = Invoke-RestMethod @restCommon -Method Post -Uri "$baseUri/SAAS/API/1.0/REST/auth/system/login" -Body $authBody
    $headers = @{ Accept = 'application/json'; Authorization = "HZN $($authResponse.sessionToken)" }
    Write-Verbose "Acquired an Identity Broker session token from $Server"

    $records = @()

    $endMs = [int64]([datetimeoffset]::UtcNow.ToUnixTimeMilliseconds())
    $startMs = $endMs - ([int64]$Days * 24 * 60 * 60 * 1000)
    Write-Verbose ("Collecting audit events over the last {0} day(s)." -f $Days)

    $page = 0
    do {
        $uri = '{0}/SAAS/jersey/manager/api/reports/audit?fromDate={1}&toDate={2}&pageSize={3}&startIndex={4}' -f `
            $baseUri, $startMs, $endMs, $PageSize, ($page * $PageSize)

        $response = $null
        try { $response = Invoke-RestMethod @restCommon -Method Get -Uri $uri -Headers $headers }
        catch {
            Write-Warning ("Audit query failed: {0}" -f $_.Exception.Message)
            break
        }

        $batch = @($response.data)
        foreach ($entry in $batch) {
            $type = $entry[1]
            if ($EventType -and $type -notin $EventType) { continue }

            $outcome = $entry[5]
            if ($FailuresOnly -and $outcome -notmatch 'FAIL|DENIED|ERROR') { continue }

            $timestamp = $null
            try { $timestamp = [datetimeoffset]::FromUnixTimeMilliseconds([int64]$entry[0]).UtcDateTime }
            catch { $timestamp = $null }

            $records += [pscustomobject]@{
                Timestamp = if ($timestamp) { $timestamp.ToString('u') } else { '' }
                EventType = $type
                Actor     = $entry[2]
                Object    = $entry[3]
                SourceIp  = $entry[4]
                Outcome   = $outcome
            }
        }

        $page++
    } while ($batch.Count -eq $PageSize -and $page -lt 40)

    $records = @($records | Sort-Object Timestamp -Descending)
    Write-Verbose ("Collected {0} audit event(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    $headers = $null
}
