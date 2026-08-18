<#
.SYNOPSIS
    Lists every workflow with its folder path, version, input parameters and when it last ran.

.DESCRIPTION
    Returns each workflow with the category path it sits under, its version and description, the
    input parameter names and types it expects, and the timestamp and state of its most recent
    execution.

    'Which of these 400 workflows does anyone still use' is answered by the last-run column, and
    it is the question that has to be answered before any orchestrator migration.

    Pain area addressed: #16 Config portability between environments; #13 Alarm noise and
    audit-trail extraction.

.PARAMETER Server
    FQDN or IP address of the VCF Operations orchestrator appliance.

.PARAMETER Credential
    Credential used to authenticate to the orchestrator API.

.PARAMETER CategoryPath
    Limit to workflows under these category paths.

.PARAMETER UnusedDays
    Return only workflows with no execution in this many days. Set 0 to return all workflows.

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
    PS> ./Export-OrchestratorWorkflow.ps1 -Server vro.example.local -Credential $cred -UnusedDays 365

    Finds workflows nobody has run in a year.

.EXAMPLE
    PS> ./Export-OrchestratorWorkflow.ps1 -Server vro.example.local -Credential $cred -OutputPath ./workflows.csv

    Writes the full workflow inventory.

.NOTES
    Author        : Sampath
    Product       : VCF Operations orchestrator (VCF 9.x)
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
    [Parameter()] [string[]]$CategoryPath,
    [Parameter()] [int]$UnusedDays = 0,
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
    Schema        = 'orchestrator.workflow'
    SchemaVersion = '1.0'
    Product       = 'vcf-operations-orchestrator'
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
    $pair = '{0}:{1}' -f $Credential.UserName, $Credential.GetNetworkCredential().Password
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair))
    $headers = @{ Accept = 'application/json'; Authorization = "Basic $encoded" }
    Write-Verbose "Prepared basic authentication for $Server"

    $records = @()

    $response = Invoke-RestMethod @restCommon -Method Get -Uri "$baseUri/vco/api/workflows" -Headers $headers
    $workflows = @($response.link)
    Write-Verbose ("Orchestrator reports {0} workflow(s)." -f $workflows.Count)

    foreach ($workflow in $workflows) {
        $attributes = @{}
        foreach ($attribute in @($workflow.attributes)) { $attributes[$attribute.name] = $attribute.value }

        $categoryPath = $attributes['categoryPath']
        if ($CategoryPath) {
            $matched = $false
            foreach ($path in $CategoryPath) { if ($categoryPath -like "$path*") { $matched = $true; break } }
            if (-not $matched) { continue }
        }

        $workflowId = $attributes['id']

        $lastRun = $null
        $lastState = ''
        try {
            $executions = Invoke-RestMethod @restCommon -Method Get `
                -Uri ('{0}/vco/api/workflows/{1}/executions?maxResult=1' -f $baseUri, $workflowId) -Headers $headers
            $latest = @($executions.relations.link) | Select-Object -First 1
            if ($latest) {
                $executionAttributes = @{}
                foreach ($attribute in @($latest.attributes)) { $executionAttributes[$attribute.name] = $attribute.value }
                if ($executionAttributes['startDate']) {
                    try { $lastRun = [datetime]$executionAttributes['startDate'] } catch { $lastRun = $null }
                }
                $lastState = $executionAttributes['state']
            }
        }
        catch { Write-Verbose "Could not read executions for workflow '$($attributes['name'])'." }

        if ($UnusedDays -gt 0) {
            if ($lastRun -and $lastRun -gt (Get-Date).AddDays(-$UnusedDays)) { continue }
        }

        $inputs = @()
        try {
            $detail = Invoke-RestMethod @restCommon -Method Get `
                -Uri ('{0}/vco/api/workflows/{1}' -f $baseUri, $workflowId) -Headers $headers
            foreach ($parameter in @($detail.'input-parameters')) {
                $inputs += ('{0}:{1}' -f $parameter.name, $parameter.type)
            }
        }
        catch { Write-Verbose "Could not read detail for workflow '$($attributes['name'])'." }

        $records += [pscustomobject]@{
            Name            = $attributes['name']
            WorkflowId      = $workflowId
            CategoryPath    = $categoryPath
            Version         = $attributes['version']
            Description     = ($attributes['description'] -replace '\s+', ' ')
            InputParameters = ($inputs -join '; ')
            InputCount      = @($inputs).Count
            LastRun         = if ($lastRun) { $lastRun.ToString('u') } else { '' }
            LastRunState    = $lastState
            DaysSinceRun    = if ($lastRun) { [int][math]::Floor(((Get-Date) - $lastRun).TotalDays) } else { $null }
        }
    }

    $records = @($records | Sort-Object CategoryPath, Name)
    Write-Verbose ("Collected {0} workflow record(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    $headers = $null
}
