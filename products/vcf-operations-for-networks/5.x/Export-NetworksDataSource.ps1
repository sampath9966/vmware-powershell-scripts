<#
.SYNOPSIS
    Lists every configured data source with its type, collector and current collection status.

.DESCRIPTION
    Returns each data source - vCenter, NSX, physical switches, firewalls - with the collector
    node handling it, whether it is enabled, and the status and message from its last collection
    attempt.

    A data source that has stopped collecting means the flow data is silently incomplete, and
    incomplete flow data produces firewall rules that break things. This is the check nobody
    runs before starting a segmentation project.

    Pain area addressed: #9 Config drift (NTP/DNS/syslog/lockdown).

.PARAMETER Server
    FQDN or IP address of the VCF Operations for Networks platform appliance.

.PARAMETER Credential
    Credential used to authenticate to the Networks API.

.PARAMETER SourceType
    Limit to these data source types, for example VCenter or NSXTManager.

.PARAMETER UnhealthyOnly
    Return only sources that are disabled or not collecting cleanly.

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
    PS> ./Export-NetworksDataSource.ps1 -Server networks.example.local -Credential $cred -UnhealthyOnly

    Lists data sources that are not collecting.

.EXAMPLE
    PS> ./Export-NetworksDataSource.ps1 -Server networks.example.local -Credential $cred -OutputPath ./sources.json -Format JSON

    Captures the source list for Import-NetworksDataSource.ps1.

.NOTES
    Author        : Sampath
    Product       : Aria Operations for Networks (VCF 5.x)
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
    [Parameter()] [string[]]$SourceType,
    [Parameter()] [switch]$UnhealthyOnly,
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
    Schema        = 'networks.data-source'
    SchemaVersion = '1.0'
    Product       = 'vcf-operations-for-networks'
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
    $authBody = @{
        username = $Credential.UserName
        password = $Credential.GetNetworkCredential().Password
        domain   = @{ domain_type = 'LOCAL' }
    } | ConvertTo-Json
    $authResponse = Invoke-RestMethod @restCommon -Method Post -Uri "$baseUri/api/ni/auth/token" -Body $authBody
    $headers = @{ Accept = 'application/json'; Authorization = "NetworkInsight $($authResponse.token)" }
    Write-Verbose "Acquired a Networks API token from $Server"

    $records = @()

    $sourceTypes = @(
        'vcenter', 'nsxt-manager', 'nsxv-manager', 'cisco-switch', 'arista-switch',
        'dell-switch', 'juniper-switch', 'panfw', 'checkpointfw', 'ucs-manager'
    )

    foreach ($type in $sourceTypes) {
        $listing = $null
        try {
            $listing = Invoke-RestMethod @restCommon -Method Get `
                -Uri ('{0}/api/ni/data-sources/{1}' -f $baseUri, $type) -Headers $headers
        }
        catch {
            Write-Verbose "No data sources of type '$type' (or the type is not supported on this build)."
            continue
        }

        foreach ($entry in @($listing.results)) {
            $detail = $null
            try {
                $detail = Invoke-RestMethod @restCommon -Method Get `
                    -Uri ('{0}/api/ni/data-sources/{1}/{2}' -f $baseUri, $type, $entry.entity_id) -Headers $headers
            }
            catch { Write-Verbose "Could not read detail for $($entry.entity_id)." }

            if (-not $detail) { continue }
            if ($SourceType -and $type -notin $SourceType) { continue }

            $enabled = [bool]$detail.enabled
            $status = $detail.status
            $healthy = $enabled -and ($status -eq 'OK' -or $status -eq 'ENABLED')

            if ($UnhealthyOnly -and $healthy) { continue }

            $records += [pscustomobject]@{
                SourceType   = $type
                EntityId     = $entry.entity_id
                Nickname     = $detail.nickname
                Fqdn         = $detail.fqdn
                IpAddress    = $detail.ip
                Username     = $detail.credentials.username
                ProxyId      = $detail.proxy_id
                Enabled      = $enabled
                Status       = $status
                Healthy      = $healthy
                Message      = ($detail.error_message -replace '\s+', ' ')
            }
        }
    }

    $records = @($records | Sort-Object Healthy, SourceType, Nickname)
    Write-Verbose ("Collected {0} data source record(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    $headers = $null
}
