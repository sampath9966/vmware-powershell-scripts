<#
.SYNOPSIS
    Exports cloud zones with their placement policy and tags, plus the flavor and image mappings behind them.

.DESCRIPTION
    Returns a row per cloud zone with its cloud account, placement policy, capability tags and
    the compute resources it covers, then a row per flavor mapping and image mapping with what
    each name resolves to in that region.

    Flavor and image mappings are the indirection layer that makes templates portable, and they
    are the first thing to go missing in a second instance - producing templates that look fine
    and fail at provisioning time with an unhelpful error.

    Pain area addressed: #16 Config portability between environments.

.PARAMETER Server
    FQDN or IP address of the VCF Automation appliance.

.PARAMETER Credential
    Credential used to authenticate to the VCF Automation API.

.PARAMETER ZoneName
    Limit zone rows to these zone names.

.PARAMETER MappingsOnly
    Return only the flavor and image mapping rows.

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
    PS> ./Export-AutomationCloudZoneMapping.ps1 -Server automation.example.local -Credential $cred -OutputPath ./zones.csv

    Writes the zone, flavor and image mapping picture.

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
    [Parameter()] [string[]]$ZoneName,
    [Parameter()] [switch]$MappingsOnly,
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
    Schema        = 'automation.cloud-zone'
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

    if (-not $MappingsOnly) {
        $zoneResponse = Invoke-RestMethod @restCommon -Method Get -Uri "$baseUri/iaas/api/zones" -Headers $headers
        $zones = @($zoneResponse.content)
        Write-Verbose ("Automation reports {0} cloud zone(s)." -f $zones.Count)

        foreach ($zone in $zones) {
            if ($ZoneName -and $zone.name -notin $ZoneName) { continue }

            $records += [pscustomobject]@{
                Kind            = 'CloudZone'
                Name            = $zone.name
                Id              = $zone.id
                CloudAccount    = $zone.cloudAccountId
                Region          = $zone.externalRegionId
                PlacementPolicy = $zone.placementPolicy
                Tags            = (@($zone.tags | ForEach-Object { '{0}:{1}' -f $_.key, $_.value }) -join '; ')
                TagsToMatch     = (@($zone.tagsToMatch | ForEach-Object { '{0}:{1}' -f $_.key, $_.value }) -join '; ')
                MappedTo        = ''
                Constraints     = ''
            }
        }
    }

    $flavorResponse = Invoke-RestMethod @restCommon -Method Get -Uri "$baseUri/iaas/api/flavor-profiles" -Headers $headers
    foreach ($mappingProfile in @($flavorResponse.content)) {
        foreach ($mapping in @($mappingProfile.flavorMappings.mapping.PSObject.Properties)) {
            $records += [pscustomobject]@{
                Kind            = 'FlavorMapping'
                Name            = $mapping.Name
                Id              = $mappingProfile.id
                CloudAccount    = $mappingProfile.cloudAccountId
                Region          = $mappingProfile.externalRegionId
                PlacementPolicy = ''
                Tags            = ''
                TagsToMatch     = ''
                MappedTo        = ('{0} cpu, {1} MB' -f $mapping.Value.cpuCount, $mapping.Value.memoryInMB)
                Constraints     = $mapping.Value.name
            }
        }
    }

    $imageResponse = Invoke-RestMethod @restCommon -Method Get -Uri "$baseUri/iaas/api/image-profiles" -Headers $headers
    foreach ($mappingProfile in @($imageResponse.content)) {
        foreach ($mapping in @($mappingProfile.imageMappings.mapping.PSObject.Properties)) {
            $records += [pscustomobject]@{
                Kind            = 'ImageMapping'
                Name            = $mapping.Name
                Id              = $mappingProfile.id
                CloudAccount    = $mappingProfile.cloudAccountId
                Region          = $mappingProfile.externalRegionId
                PlacementPolicy = ''
                Tags            = ''
                TagsToMatch     = ''
                MappedTo        = $mapping.Value.name
                Constraints     = (@($mapping.Value.constraints | ForEach-Object { '{0}:{1}' -f $_.expression, $_.mandatory }) -join '; ')
            }
        }
    }

    $records = @($records | Sort-Object Kind, Region, Name)
    Write-Verbose ("Collected {0} zone and mapping row(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    $headers = $null
}
