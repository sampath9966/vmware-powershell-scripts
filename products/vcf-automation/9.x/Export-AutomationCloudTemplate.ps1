<#
.SYNOPSIS
    Exports cloud templates with their project, released version and full YAML content.

.DESCRIPTION
    Returns each cloud template with the project it belongs to, its status, whether a version
    has been released to the catalog, its version count and the template YAML itself.

    The YAML is the artefact. Keeping it in a file that can go into source control is the thing
    most Automation estates never get around to, and it is what
    Import-AutomationCloudTemplate.ps1 replays into another instance.

    Pain area addressed: #16 Config portability between environments.

.PARAMETER Server
    FQDN or IP address of the VCF Automation appliance.

.PARAMETER Credential
    Credential used to authenticate to the VCF Automation API.

.PARAMETER ProjectName
    Limit to templates in these projects.

.PARAMETER ReleasedOnly
    Return only templates with a released version.

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
    PS> ./Export-AutomationCloudTemplate.ps1 -Server automation.example.local -Credential $cred -OutputPath ./templates.json -Format JSON

    Captures every cloud template including its YAML.

.NOTES
    Author        : Sampath
    Product       : VCF Automation (VCF 9.x)
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
    [Parameter()] [string[]]$ProjectName,
    [Parameter()] [switch]$ReleasedOnly,
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
    Schema        = 'automation.cloud-template'
    SchemaVersion = '1.0'
    Product       = 'vcf-automation'
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
    $refresh = Invoke-RestMethod @restCommon -Method Post -Uri "$baseUri/csp/gateway/am/api/login?access_token" -Body $authBody
    $exchange = @{ refreshToken = $refresh.refresh_token } | ConvertTo-Json
    $access = Invoke-RestMethod @restCommon -Method Post -Uri "$baseUri/iaas/api/login" -Body $exchange
    $headers = @{ Accept = 'application/json'; Authorization = "Bearer $($access.token)" }
    Write-Verbose "Acquired a VCF Automation access token from $Server"

    $records = @()

    $response = Invoke-RestMethod @restCommon -Method Get -Uri "$baseUri/blueprint/api/blueprints?`$top=500" -Headers $headers
    $templates = @($response.content)
    Write-Verbose ("Automation reports {0} cloud template(s)." -f $templates.Count)

    foreach ($template in $templates) {
        if ($ProjectName -and $template.projectName -notin $ProjectName) { continue }

        $detail = $null
        try {
            $detail = Invoke-RestMethod @restCommon -Method Get `
                -Uri ('{0}/blueprint/api/blueprints/{1}' -f $baseUri, $template.id) -Headers $headers
        }
        catch { Write-Verbose "Could not read template '$($template.name)'." }

        $versions = @()
        try {
            $versionResponse = Invoke-RestMethod @restCommon -Method Get `
                -Uri ('{0}/blueprint/api/blueprints/{1}/versions' -f $baseUri, $template.id) -Headers $headers
            $versions = @($versionResponse.content)
        }
        catch { Write-Verbose "Could not read versions for '$($template.name)'." }

        $released = @($versions | Where-Object { $_.status -eq 'RELEASED' })
        if ($ReleasedOnly -and -not $released) { continue }

        $records += [pscustomobject]@{
            Name            = $template.name
            TemplateId      = $template.id
            Project         = $template.projectName
            ProjectId       = $template.projectId
            Description     = ($template.description -replace '\s+', ' ')
            Status          = $template.status
            VersionCount    = $versions.Count
            LatestVersion   = (@($versions.version) | Select-Object -First 1)
            ReleasedVersion = (@($released.version) | Select-Object -First 1)
            RequestScopeOrg = $template.requestScopeOrg
            CreatedAt       = $template.createdAt
            UpdatedAt       = $template.updatedAt
            Content         = if ($detail) { $detail.content } else { '' }
        }
    }

    $records = @($records | Sort-Object Project, Name)
    Write-Verbose ("Collected {0} cloud template record(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    $headers = $null
}
