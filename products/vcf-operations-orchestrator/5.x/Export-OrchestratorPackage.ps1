<#
.SYNOPSIS
    Lists packages with the workflows, actions and configuration elements each contains, and can save the package files.

.DESCRIPTION
    Returns each package with its name and description and a count of the workflows, actions,
    configuration elements and resource elements it holds. With -PackageDirectory the actual
    .package file for each is downloaded as well.

    Packages are how orchestrator content moves between environments, and the downloaded files
    are what Import-OrchestratorPackage.ps1 needs.

    Pain area addressed: #16 Config portability between environments.

.PARAMETER Server
    FQDN or IP address of the VCF Operations orchestrator appliance.

.PARAMETER Credential
    Credential used to authenticate to the orchestrator API.

.PARAMETER PackageName
    Limit to these package names.

.PARAMETER PackageDirectory
    Directory to download the .package files into. Omit to collect metadata only.

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
    PS> ./Export-OrchestratorPackage.ps1 -Server vro.example.local -Credential $cred -PackageDirectory ./packages -OutputPath ./packages.json -Format JSON

    Downloads every package and writes the inventory alongside.

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
    [Parameter()] [string[]]$PackageName,
    [Parameter()] [string]$PackageDirectory,
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
    Schema        = 'orchestrator.package'
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

    if ($PackageDirectory -and -not (Test-Path -LiteralPath $PackageDirectory)) {
        New-Item -ItemType Directory -Path $PackageDirectory -Force | Out-Null
    }

    $response = Invoke-RestMethod @restCommon -Method Get -Uri "$baseUri/vco/api/packages" -Headers $headers
    $packages = @($response.link)
    Write-Verbose ("Orchestrator reports {0} package(s)." -f $packages.Count)

    foreach ($package in $packages) {
        $attributes = @{}
        foreach ($attribute in @($package.attributes)) { $attributes[$attribute.name] = $attribute.value }

        $name = $attributes['name']
        if ($PackageName -and $name -notin $PackageName) { continue }

        $detail = $null
        try {
            $detail = Invoke-RestMethod @restCommon -Method Get `
                -Uri ('{0}/vco/api/packages/{1}' -f $baseUri, $name) -Headers $headers
        }
        catch { Write-Verbose "Could not read package '$name'." }

        $savedTo = ''
        if ($PackageDirectory) {
            $target = Join-Path $PackageDirectory ($name + '.package')
            try {
                $downloadHeaders = @{ Authorization = $headers.Authorization; Accept = 'application/zip' }
                Invoke-RestMethod @restCommon -Method Get -Uri ('{0}/vco/api/packages/{1}' -f $baseUri, $name) `
                    -Headers $downloadHeaders -OutFile $target
                $savedTo = $target
                Write-Verbose "Saved package '$name' to $target."
            }
            catch { Write-Warning ("Could not download package '{0}': {1}" -f $name, $_.Exception.Message) }
        }

        $records += [pscustomobject]@{
            Name           = $name
            Description    = ($attributes['description'] -replace '\s+', ' ')
            Workflows      = @($detail.workflows).Count
            Actions        = @($detail.actions).Count
            Configurations = @($detail.configurations).Count
            Resources      = @($detail.resources).Count
            SavedTo        = $savedTo
        }
    }

    $records = @($records | Sort-Object Name)
    Write-Verbose ("Collected {0} package record(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    $headers = $null
}
