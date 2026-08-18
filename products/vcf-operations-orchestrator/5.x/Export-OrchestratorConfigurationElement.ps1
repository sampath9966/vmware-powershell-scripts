<#
.SYNOPSIS
    Exports configuration elements with their attribute names, types and values, masking anything that looks secret.

.DESCRIPTION
    Returns each configuration element with its category path, version and one row per
    attribute: name, type and value. Attributes whose type is SecureString, or whose name
    contains password, secret, token or key, have their value replaced with a marker rather than
    exported.

    Configuration elements hold the endpoint addresses and settings every workflow reads, which
    makes them both the most important thing to document and the most dangerous to dump
    carelessly. Import-OrchestratorConfigurationElement.ps1 replays the non-secret values.

    Pain area addressed: #16 Config portability between environments.

.PARAMETER Server
    FQDN or IP address of the VCF Operations orchestrator appliance.

.PARAMETER Credential
    Credential used to authenticate to the orchestrator API.

.PARAMETER CategoryPath
    Limit to elements under these category paths.

.PARAMETER IncludeSecretNames
    Include rows for secret attributes with their value masked. Off by default, which omits them
    entirely.

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
    PS> ./Export-OrchestratorConfigurationElement.ps1 -Server vro.example.local -Credential $cred -OutputPath ./configs.json -Format JSON

    Captures configuration elements with secrets excluded.

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
    [Parameter()] [string[]]$CategoryPath,
    [Parameter()] [switch]$IncludeSecretNames,
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
    Schema        = 'orchestrator.configuration-element'
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

    $secretPattern = 'password|secret|token|apikey|api_key|credential|privatekey'

    $response = Invoke-RestMethod @restCommon -Method Get -Uri "$baseUri/vco/api/configurations" -Headers $headers
    $elements = @($response.link)
    Write-Verbose ("Orchestrator reports {0} configuration element(s)." -f $elements.Count)

    foreach ($element in $elements) {
        $attributes = @{}
        foreach ($attribute in @($element.attributes)) { $attributes[$attribute.name] = $attribute.value }

        $categoryPath = $attributes['categoryPath']
        if ($CategoryPath) {
            $matched = $false
            foreach ($path in $CategoryPath) { if ($categoryPath -like "$path*") { $matched = $true; break } }
            if (-not $matched) { continue }
        }

        $detail = $null
        try {
            $detail = Invoke-RestMethod @restCommon -Method Get `
                -Uri ('{0}/vco/api/configurations/{1}' -f $baseUri, $attributes['id']) -Headers $headers
        }
        catch {
            Write-Verbose "Could not read configuration element '$($attributes['name'])'."
            continue
        }

        foreach ($configAttribute in @($detail.attributes)) {
            $isSecret = ($configAttribute.type -eq 'SecureString') -or ($configAttribute.name -match $secretPattern)

            if ($isSecret -and -not $IncludeSecretNames) { continue }

            $records += [pscustomobject]@{
                Element       = $detail.name
                ElementId     = $attributes['id']
                CategoryPath  = $categoryPath
                Version       = $detail.version
                AttributeName = $configAttribute.name
                AttributeType = $configAttribute.type
                Value         = if ($isSecret) { '(secret - not exported)' } else { [string]$configAttribute.value.string }
                IsSecret      = $isSecret
                Description   = ($configAttribute.description -replace '\s+', ' ')
            }
        }
    }

    $records = @($records | Sort-Object CategoryPath, Element, AttributeName)
    Write-Verbose ("Collected {0} attribute row(s). Secret values are never included." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    $headers = $null
}
