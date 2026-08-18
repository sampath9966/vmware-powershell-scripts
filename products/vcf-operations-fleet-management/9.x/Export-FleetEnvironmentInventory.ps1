<#
.SYNOPSIS
    Lists every managed environment with each product in it, its version and deployment state.

.DESCRIPTION
    Walks the environments fleet management knows about and returns one row per product: the
    environment it belongs to, product id and version, deployment type, node count and current
    state - so the version position of the whole suite is one table rather than a click per
    tile.

    This is the inventory an upgrade plan starts from, and the one that is always slightly out
    of date in the change record because nobody can export it.

    Pain area addressed: #3 BOM / version drift per domain.

.PARAMETER Server
    FQDN or IP address of the VCF Operations fleet management (Aria Suite Lifecycle) appliance.

.PARAMETER Credential
    Credential used to authenticate to the fleet management API.

.PARAMETER EnvironmentName
    Limit to these environment names.

.PARAMETER ProductId
    Limit to these product ids, for example vrops, vra or vrli.

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
    PS> ./Export-FleetEnvironmentInventory.ps1 -Server lcm.example.local -Credential $cred -OutputPath ./fleet.csv

    Writes the full product and version position.

.NOTES
    Author        : Sampath
    Product       : VCF Operations fleet management (VCF 9.x)
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
    [Parameter()] [string[]]$EnvironmentName,
    [Parameter()] [string[]]$ProductId,
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
    Schema        = 'fleet.environment-inventory'
    SchemaVersion = '1.0'
    Product       = 'vcf-operations-fleet-management'
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

    $environments = Invoke-RestMethod @restCommon -Method Get -Uri "$baseUri/lcm/lcops/api/v2/environments" -Headers $headers
    Write-Verbose ("Fleet management reports {0} environment(s)." -f @($environments).Count)

    foreach ($environment in @($environments)) {
        if ($EnvironmentName -and $environment.environmentName -notin $EnvironmentName) { continue }

        foreach ($product in @($environment.products)) {
            if ($ProductId -and $product.id -notin $ProductId) { continue }

            $nodeCount = 0
            foreach ($node in @($product.nodes)) { $nodeCount++ }

            $records += [pscustomobject]@{
                Environment     = $environment.environmentName
                EnvironmentId   = $environment.environmentId
                DataCenter      = $environment.dataCenterName
                ProductId       = $product.id
                ProductVersion  = $product.version
                DeploymentType  = $product.deploymentType
                NodeCount       = $nodeCount
                NodeHostnames   = (@($product.nodes.properties.vmName) -join '; ')
                Status          = $product.status
                EnvironmentStatus = $environment.status
            }
        }
    }

    $records = @($records | Sort-Object Environment, ProductId)
    Write-Verbose ("Collected {0} product row(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    $headers = $null
}
