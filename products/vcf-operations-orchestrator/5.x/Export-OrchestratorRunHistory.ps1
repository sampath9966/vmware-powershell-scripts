<#
.SYNOPSIS
    Extracts workflow execution history with duration, state, who ran it and the failure message.

.DESCRIPTION
    Returns one row per execution over the window you choose, carrying the workflow name, start
    and end time, calculated duration, the business state, the user who started it and the
    exception text where it failed.

    Failed executions are the invisible problem in most orchestrator estates: a workflow called
    from a subscription fails, nothing alerts, and the automation quietly stops working.
    Filtering this to State -eq 'failed' surfaces the whole set at once.

    Pain area addressed: #13 Alarm noise and audit-trail extraction.

.PARAMETER Server
    FQDN or IP address of the VCF Operations orchestrator appliance.

.PARAMETER Credential
    Credential used to authenticate to the orchestrator API.

.PARAMETER Days
    How many days of history to collect. Defaults to 7.

.PARAMETER FailuresOnly
    Return only executions that did not complete successfully.

.PARAMETER MaxPerWorkflow
    How many executions to read per workflow. Defaults to 50.

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
    PS> ./Export-OrchestratorRunHistory.ps1 -Server vro.example.local -Credential $cred -FailuresOnly -Days 30

    Lists every failed workflow run in the last month.

.NOTES
    Author        : Sampath
    Product       : Aria Automation Orchestrator (VCF 5.x)
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
    [Parameter()] [switch]$FailuresOnly,
    [Parameter()] [int]$MaxPerWorkflow = 50,
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
    Schema        = 'orchestrator.run-history'
    SchemaVersion = '1.0'
    Product       = 'vcf-operations-orchestrator'
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

    $cutoff = (Get-Date).AddDays(-$Days)

    $response = Invoke-RestMethod @restCommon -Method Get -Uri "$baseUri/vco/api/workflows" -Headers $headers
    $workflows = @($response.link)
    Write-Verbose ("Reading executions for {0} workflow(s) back to {1:u}." -f $workflows.Count, $cutoff)

    foreach ($workflow in $workflows) {
        $attributes = @{}
        foreach ($attribute in @($workflow.attributes)) { $attributes[$attribute.name] = $attribute.value }
        $workflowId = $attributes['id']

        $executions = $null
        try {
            $executions = Invoke-RestMethod @restCommon -Method Get `
                -Uri ('{0}/vco/api/workflows/{1}/executions?maxResult={2}' -f $baseUri, $workflowId, $MaxPerWorkflow) -Headers $headers
        }
        catch { continue }

        foreach ($execution in @($executions.relations.link)) {
            $executionAttributes = @{}
            foreach ($attribute in @($execution.attributes)) { $executionAttributes[$attribute.name] = $attribute.value }

            $start = $null
            $end = $null
            try { if ($executionAttributes['startDate']) { $start = [datetime]$executionAttributes['startDate'] } } catch { $start = $null }
            try { if ($executionAttributes['endDate']) { $end = [datetime]$executionAttributes['endDate'] } } catch { $end = $null }

            if ($start -and $start -lt $cutoff) { continue }

            $state = $executionAttributes['state']
            if ($FailuresOnly -and $state -in @('completed', 'running')) { continue }

            $records += [pscustomobject]@{
                Workflow        = $attributes['name']
                CategoryPath    = $attributes['categoryPath']
                ExecutionId     = $executionAttributes['id']
                State           = $state
                StartedBy       = $executionAttributes['startedBy']
                Started         = $executionAttributes['startDate']
                Ended           = $executionAttributes['endDate']
                DurationSeconds = if ($start -and $end) { [int]($end - $start).TotalSeconds } else { $null }
                Message         = ($executionAttributes['contentException'] -replace '\s+', ' ')
            }
        }
    }

    $records = @($records | Sort-Object Started -Descending)
    Write-Verbose ("Collected {0} execution record(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    $headers = $null
}
