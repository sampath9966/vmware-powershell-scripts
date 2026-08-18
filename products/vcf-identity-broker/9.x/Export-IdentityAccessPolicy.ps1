<#
.SYNOPSIS
    Exports access policies with each rule in order - network range, device type, authentication method and fallback.

.DESCRIPTION
    Returns one row per policy rule carrying the policy it belongs to, the rule's position in
    the evaluation order, the network range and device type it matches, the authentication
    method it requires, its fallback method and the re-authentication interval.

    Rule order is everything in an access policy and it is invisible in any export the product
    offers. Getting it wrong locks people out or lets them in without a second factor, and this
    is the only way to review it as a whole.

    Pain area addressed: #16 Config portability between environments.

.PARAMETER Server
    FQDN or IP address of the VCF Identity Broker appliance.

.PARAMETER Credential
    Credential used to authenticate to the Identity Broker API.

.PARAMETER PolicyName
    Limit to these policy names.

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
    PS> ./Export-IdentityAccessPolicy.ps1 -Server idb.example.local -Credential $cred -OutputPath ./policies.json -Format JSON

    Captures every access policy rule in evaluation order.

.NOTES
    Author        : Sampath
    Product       : VCF Identity Broker (VCF 9.x)
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
    [Parameter()] [string[]]$PolicyName,
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
    Schema        = 'identity.access-policy'
    SchemaVersion = '1.0'
    Product       = 'vcf-identity-broker'
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
    $authBody = @{ username = $Credential.UserName; password = $Credential.GetNetworkCredential().Password; issueToken = $true } | ConvertTo-Json
    $authResponse = Invoke-RestMethod @restCommon -Method Post -Uri "$baseUri/SAAS/API/1.0/REST/auth/system/login" -Body $authBody
    $headers = @{ Accept = 'application/json'; Authorization = "HZN $($authResponse.sessionToken)" }
    Write-Verbose "Acquired an Identity Broker session token from $Server"

    $records = @()

    $response = Invoke-RestMethod @restCommon -Method Get -Uri "$baseUri/SAAS/jersey/manager/api/accessPolicies" -Headers $headers
    $policies = @($response.items)
    Write-Verbose ("Identity Broker reports {0} access policy/policies." -f $policies.Count)

    foreach ($policy in $policies) {
        if ($PolicyName -and $policy.name -notin $PolicyName) { continue }

        $ruleIndex = 0
        foreach ($rule in @($policy.rules)) {
            $ruleIndex++

            $authMethods = @()
            foreach ($chain in @($rule.authenticationMethods)) {
                $authMethods += (@($chain.authMethods.name) -join ' + ')
            }

            $records += [pscustomobject]@{
                Policy              = $policy.name
                PolicyId            = $policy.uuid
                Description         = ($policy.description -replace '\s+', ' ')
                RuleOrder           = $ruleIndex
                RuleDescription     = ($rule.description -replace '\s+', ' ')
                NetworkRanges       = (@($rule.conditions.networkRanges.name) -join '; ')
                DeviceTypes         = (@($rule.conditions.clientTypes) -join '; ')
                Groups              = (@($rule.conditions.groups.name) -join '; ')
                AuthenticationChain = ($authMethods -join ' | ')
                FallbackMethod      = $rule.fallbackMethod
                ReAuthMinutes       = $rule.reAuthnSeconds
                ActionType          = $rule.actionType
            }
        }
    }

    $records = @($records | Sort-Object Policy, RuleOrder)
    Write-Verbose ("Collected {0} policy rule row(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    $headers = $null
}
