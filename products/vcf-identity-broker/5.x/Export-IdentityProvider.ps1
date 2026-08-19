<#
.SYNOPSIS
    Exports the configured identity providers with their type, authentication methods and the directories they serve.

.DESCRIPTION
    Returns each identity provider with its type, whether it is enabled, the authentication
    methods it exposes, the directories it is bound to and the network ranges it applies to.

    When a login starts failing, the first question is which provider handled it, and the answer
    needs all four of those columns at once. This is also the record to have before anyone
    reconfigures federation.

    Pain area addressed: #16 Config portability between environments.

.PARAMETER Server
    FQDN or IP address of the VCF Identity Broker appliance.

.PARAMETER Credential
    Credential used to authenticate to the Identity Broker API.

.PARAMETER ProviderName
    Limit to these identity provider names.

.PARAMETER EnabledOnly
    Return only enabled providers.

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
    PS> ./Export-IdentityProvider.ps1 -Server idb.example.local -Credential $cred -OutputPath ./idp.json -Format JSON

    Captures the identity provider configuration.

.NOTES
    Author        : Sampath
    Product       : Workspace ONE Access (VCF 5.x)
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
    [Parameter()] [string[]]$ProviderName,
    [Parameter()] [switch]$EnabledOnly,
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
    Schema        = 'identity.provider'
    SchemaVersion = '1.0'
    Product       = 'vcf-identity-broker'
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
    $authBody = @{ username = $Credential.UserName; password = $Credential.GetNetworkCredential().Password; issueToken = $true } | ConvertTo-Json
    $authResponse = Invoke-RestMethod @restCommon -Method Post -Uri "$baseUri/SAAS/API/1.0/REST/auth/system/login" -Body $authBody
    $headers = @{ Accept = 'application/json'; Authorization = "HZN $($authResponse.sessionToken)" }
    Write-Verbose "Acquired an Identity Broker session token from $Server"

    $records = @()

    $response = Invoke-RestMethod @restCommon -Method Get -Uri "$baseUri/SAAS/jersey/manager/api/identityProviders" -Headers $headers
    $providers = @($response.items)
    Write-Verbose ("Identity Broker reports {0} identity provider(s)." -f $providers.Count)

    foreach ($provider in $providers) {
        if ($ProviderName -and $provider.name -notin $ProviderName) { continue }

        $enabled = [bool]$provider.enabled
        if ($EnabledOnly -and -not $enabled) { continue }

        $records += [pscustomobject]@{
            Name                 = $provider.name
            ProviderId           = $provider.id
            Type                 = $provider.type
            Enabled              = $enabled
            Description          = ($provider.description -replace '\s+', ' ')
            AuthenticationMethods = (@($provider.authMethods.name) -join '; ')
            Directories          = (@($provider.directories.name) -join '; ')
            NetworkRanges        = (@($provider.networkRanges.name) -join '; ')
            MetadataUrl          = $provider.metaData
            JitEnabled           = $provider.jitEnabled
        }
    }

    $records = @($records | Sort-Object Name)
    Write-Verbose ("Collected {0} identity provider record(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    $headers = $null
}
