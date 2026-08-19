<#
.SYNOPSIS
    Exports alert definitions with their symptom sets and recommendations, ready to replay elsewhere.

.DESCRIPTION
    Pulls every alert definition with its adapter and resource kind, criticality, wait and
    cancel cycles, the symptom set expressions it depends on, and the recommendations attached
    to it - flattened so the file is both readable and replayable.

    Hand-tuned alert definitions are real engineering effort that lives in one appliance. This
    makes them a file you can review, diff and push into a second instance with
    Import-OpsAlertDefinition.ps1.

    Pain area addressed: #13 Alarm noise and audit-trail extraction; #16 Config portability
    between environments.

.PARAMETER Server
    FQDN or IP address of the VCF Operations node.

.PARAMETER Credential
    Credential used to authenticate to the VCF Operations API.

.PARAMETER AdapterKind
    Limit to definitions belonging to these adapter kinds, for example VMWARE.

.PARAMETER ResourceKind
    Limit to definitions targeting these resource kinds.

.PARAMETER PageSize
    How many definitions to request per API call. Defaults to 500.

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
    PS> ./Export-OpsAlertDefinition.ps1 -Server ops.example.local -Credential $cred -OutputPath ./alertdefs.json -Format JSON

    Captures every alert definition for replay.

.NOTES
    Author        : Sampath
    Product       : VCF Operations (VCF 9.x)
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
    [Parameter()] [string[]]$AdapterKind,
    [Parameter()] [string[]]$ResourceKind,
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
    Schema        = 'vcf-operations.alert-definition'
    SchemaVersion = '1.0'
    Product       = 'vcf-operations'
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
    $authBody = @{ username = $Credential.UserName; password = $Credential.GetNetworkCredential().Password } | ConvertTo-Json
    $authResponse = Invoke-RestMethod @restCommon -Method Post -Uri "$baseUri/suite-api/api/auth/token/acquire" -Headers @{ Accept = 'application/json' } -Body $authBody
    $headers = @{ Accept = 'application/json'; Authorization = "vRealizeOpsToken $($authResponse.token)" }
    Write-Verbose "Acquired a VCF Operations API token from $Server"

    $records = @()

    $symptomsByName = @{}
    $page = 0
    do {
        $uri = '{0}/suite-api/api/symptomdefinitions?page={1}&pageSize={2}' -f $baseUri, $page, $PageSize
        $response = Invoke-RestMethod @restCommon -Method Get -Uri $uri -Headers $headers
        foreach ($symptom in @($response.symptomDefinitions)) { $symptomsByName[$symptom.id] = $symptom }
        $page++
    } while (@($response.symptomDefinitions).Count -eq $PageSize)
    Write-Verbose ("Loaded {0} symptom definition(s)." -f $symptomsByName.Count)

    $page = 0
    do {
        $uri = '{0}/suite-api/api/alertdefinitions?page={1}&pageSize={2}' -f $baseUri, $page, $PageSize
        $response = Invoke-RestMethod @restCommon -Method Get -Uri $uri -Headers $headers

        foreach ($definition in @($response.alertDefinitions)) {
            if ($AdapterKind -and $definition.adapterKindKey -notin $AdapterKind) { continue }
            if ($ResourceKind -and $definition.resourceKindKey -notin $ResourceKind) { continue }

            $symptomText = @()
            foreach ($state in @($definition.states)) {
                foreach ($condition in @($state.base_symptom_set.symptomDefinitionIds)) {
                    $symptom = $symptomsByName[$condition]
                    $symptomText += if ($symptom) { $symptom.name } else { $condition }
                }
            }

            $records += [pscustomobject]@{
                Id              = $definition.id
                Name            = $definition.name
                Description     = ($definition.description -replace '\s+', ' ')
                AdapterKind     = $definition.adapterKindKey
                ResourceKind    = $definition.resourceKindKey
                Type            = $definition.type
                SubType         = $definition.subType
                WaitCycles      = $definition.waitCycles
                CancelCycles    = $definition.cancelCycles
                Criticality     = (@($definition.states).severity -join '; ')
                Symptoms        = ($symptomText -join '; ')
                SymptomCount    = @($symptomText).Count
                Recommendations = (@($definition.states).recommendationPriorityMap.PSObject.Properties.Name -join '; ')
            }
        }

        $page++
    } while (@($response.alertDefinitions).Count -eq $PageSize)

    $records = @($records | Sort-Object AdapterKind, ResourceKind, Name)
    Write-Verbose ("Collected {0} alert definition(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    $headers = $null
}
