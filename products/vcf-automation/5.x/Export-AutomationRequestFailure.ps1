<#
.SYNOPSIS
    Extracts deployment request history with the failure detail, so recurring provisioning errors are countable.

.DESCRIPTION
    Returns each request over the window with its type, the deployment and project it belongs
    to, who submitted it, its status, duration and the detailed error message where it failed.

    Grouping this by the error message turns 'provisioning is flaky' into 'forty-one of the last
    fifty failures were the same IP pool exhaustion', which is a fixable statement.

    Pain area addressed: #13 Alarm noise and audit-trail extraction.

.PARAMETER Server
    FQDN or IP address of the VCF Automation appliance.

.PARAMETER Credential
    Credential used to authenticate to the VCF Automation API.

.PARAMETER Days
    How many days of request history to collect. Defaults to 14.

.PARAMETER FailuresOnly
    Return only requests that failed.

.PARAMETER PageSize
    How many requests to request per call. Defaults to 200.

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
    PS> ./Export-AutomationRequestFailure.ps1 -Server automation.example.local -Credential $cred -FailuresOnly | Group-Object Message | Sort-Object Count -Descending

    Ranks provisioning failures by cause.

.NOTES
    Author        : Sampath
    Product       : Aria Automation (VCF 5.x)
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
    [Parameter()] [int]$Days = 14,
    [Parameter()] [switch]$FailuresOnly,
    [Parameter()] [int]$PageSize = 200,
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
    Schema        = 'automation.request-failure'
    SchemaVersion = '1.0'
    Product       = 'vcf-automation'
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
    $authBody = @{ username = $Credential.UserName; password = $Credential.GetNetworkCredential().Password } | ConvertTo-Json
    $refresh = Invoke-RestMethod @restCommon -Method Post -Uri "$baseUri/csp/gateway/am/api/login?access_token" -Body $authBody
    $exchange = @{ refreshToken = $refresh.refresh_token } | ConvertTo-Json
    $access = Invoke-RestMethod @restCommon -Method Post -Uri "$baseUri/iaas/api/login" -Body $exchange
    $headers = @{ Accept = 'application/json'; Authorization = "Bearer $($access.token)" }
    Write-Verbose "Acquired a VCF Automation access token from $Server"

    $records = @()

    $cutoff = (Get-Date).AddDays(-$Days)
    $page = 0

    do {
        $uri = '{0}/deployment/api/requests?size={1}&page={2}' -f $baseUri, $PageSize, $page
        $response = Invoke-RestMethod @restCommon -Method Get -Uri $uri -Headers $headers
        $batch = @($response.content)

        foreach ($request in $batch) {
            $created = $null
            $updated = $null
            try { if ($request.createdAt) { $created = [datetime]$request.createdAt } } catch { $created = $null }
            try { if ($request.updatedAt) { $updated = [datetime]$request.updatedAt } } catch { $updated = $null }

            if ($created -and $created -lt $cutoff) { continue }

            $status = $request.status
            if ($FailuresOnly -and $status -ne 'FAILED') { continue }

            $records += [pscustomobject]@{
                RequestId       = $request.id
                Name            = $request.name
                ActionId        = $request.actionId
                DeploymentId    = $request.deploymentId
                Project         = $request.projectId
                RequestedBy     = $request.requestedBy
                Status          = $status
                Created         = $request.createdAt
                Updated         = $request.updatedAt
                DurationMinutes = if ($created -and $updated) { [int]($updated - $created).TotalMinutes } else { $null }
                Message         = ($request.details -replace '\s+', ' ')
            }
        }

        $page++
    } while ($batch.Count -eq $PageSize -and $page -lt 50)

    $records = @($records | Sort-Object Created -Descending)
    Write-Verbose ("Collected {0} request record(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    $headers = $null
}
