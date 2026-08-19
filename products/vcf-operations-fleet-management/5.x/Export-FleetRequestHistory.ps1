<#
.SYNOPSIS
    Extracts the request history with per-request state, duration and the failure message where there is one.

.DESCRIPTION
    Returns each request with its type, the environment it targeted, who submitted it, start and
    end time, calculated duration and final state - plus the error message for anything that
    failed.

    Failed requests are where upgrade postmortems start, and reading them in the UI means
    opening each one. Filtering this to State -eq 'FAILED' gives the whole history at once.

    Pain area addressed: #12 Upgrade prechecks and bundle state; #13 Alarm noise and audit-trail
    extraction.

.PARAMETER Server
    FQDN or IP address of the VCF Operations fleet management (Aria Suite Lifecycle) appliance.

.PARAMETER Credential
    Credential used to authenticate to the fleet management API.

.PARAMETER Days
    How many days of history to return. Defaults to 30.

.PARAMETER FailuresOnly
    Return only requests that did not complete successfully.

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
    PS> ./Export-FleetRequestHistory.ps1 -Server lcm.example.local -Credential $cred -FailuresOnly -Days 90

    Lists every failed request in the last quarter with its error.

.NOTES
    Author        : Sampath
    Product       : Aria Suite Lifecycle (VCF 5.x)
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
    [Parameter()] [int]$Days = 30,
    [Parameter()] [switch]$FailuresOnly,
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
    Schema        = 'fleet.request-history'
    SchemaVersion = '1.0'
    Product       = 'vcf-operations-fleet-management'
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
    $pair = '{0}:{1}' -f $Credential.UserName, $Credential.GetNetworkCredential().Password
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair))
    $headers = @{ Accept = 'application/json'; Authorization = "Basic $encoded" }
    Write-Verbose "Prepared basic authentication for $Server"

    $records = @()

    $response = Invoke-RestMethod @restCommon -Method Get -Uri "$baseUri/lcm/request/api/v2/requests" -Headers $headers
    $requests = @($response)
    Write-Verbose ("Fleet management reports {0} request(s)." -f $requests.Count)

    $cutoff = (Get-Date).AddDays(-$Days)

    foreach ($request in $requests) {
        $start = $null
        $end = $null
        try { if ($request.requestSubmissionTime) { $start = [datetime]$request.requestSubmissionTime } } catch { $start = $null }
        try { if ($request.requestCompletionTime) { $end = [datetime]$request.requestCompletionTime } } catch { $end = $null }

        if ($start -and $start -lt $cutoff) { continue }

        $state = $request.state
        if ($FailuresOnly -and $state -in @('COMPLETED', 'SUCCESSFUL')) { continue }

        $durationMinutes = $null
        if ($start -and $end) { $durationMinutes = [int][math]::Round(($end - $start).TotalMinutes, 0) }

        $records += [pscustomobject]@{
            RequestId       = $request.requestId
            RequestType     = $request.requestType
            Environment     = $request.requestName
            State           = $state
            SubmittedBy     = $request.requestedBy
            Started         = $request.requestSubmissionTime
            Completed       = $request.requestCompletionTime
            DurationMinutes = $durationMinutes
            Message         = ($request.errorCause -replace '\s+', ' ')
        }
    }

    $records = @($records | Sort-Object Started -Descending)
    Write-Verbose ("Collected {0} request record(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    $headers = $null
}
