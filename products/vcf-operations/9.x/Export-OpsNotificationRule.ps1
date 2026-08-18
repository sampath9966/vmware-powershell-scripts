<#
.SYNOPSIS
    Exports notification rules with their plugin target, filter criteria and the alert definitions they act on.

.DESCRIPTION
    Returns each notification rule with the outbound plugin it uses, the recipients or target it
    delivers to, and the filter that decides which alerts it fires for - criticality, resource
    kind, alert definition and status.

    'Why did nobody get paged for that' is answered by this table, and the answer is almost
    always a filter that is narrower than anyone remembered. It is also a record worth having
    before an upgrade rewrites the plugin configuration.

    Pain area addressed: #13 Alarm noise and audit-trail extraction; #16 Config portability
    between environments.

.PARAMETER Server
    FQDN or IP address of the VCF Operations node.

.PARAMETER Credential
    Credential used to authenticate to the VCF Operations API.

.PARAMETER PluginType
    Limit to rules using these outbound plugin types.

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
    PS> ./Export-OpsNotificationRule.ps1 -Server ops.example.local -Credential $cred -OutputPath ./notifications.csv

    Writes every notification rule and its filter.

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
    [Parameter()] [string[]]$PluginType,
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
    Schema        = 'vcf-operations.notification-rule'
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

    $pluginResponse = Invoke-RestMethod @restCommon -Method Get -Uri "$baseUri/suite-api/api/alertplugins" -Headers $headers
    $pluginById = @{}
    foreach ($plugin in @($pluginResponse.notificationPluginInstances)) { $pluginById[$plugin.pluginId] = $plugin }
    Write-Verbose ("Found {0} outbound plugin instance(s)." -f $pluginById.Count)

    $response = Invoke-RestMethod @restCommon -Method Get -Uri "$baseUri/suite-api/api/notifications/rules" -Headers $headers
    $rules = @($response.notificationRuleList)
    Write-Verbose ("Found {0} notification rule(s)." -f $rules.Count)

    foreach ($rule in $rules) {
        $plugin = $pluginById[$rule.pluginId]
        if ($PluginType -and (-not $plugin -or $plugin.pluginTypeId -notin $PluginType)) { continue }

        $criteria = @()
        if ($rule.alertControlStates) { $criteria += ('controlState in ' + (@($rule.alertControlStates) -join ',')) }
        if ($rule.alertStatuses) { $criteria += ('status in ' + (@($rule.alertStatuses) -join ',')) }
        if ($rule.criticalities) { $criteria += ('criticality in ' + (@($rule.criticalities) -join ',')) }
        if ($rule.resourceKindFilter) {
            $criteria += ('resourceKind = {0}/{1}' -f $rule.resourceKindFilter.adapterKind, $rule.resourceKindFilter.resourceKind)
        }
        if ($rule.alertDefinitionIdFilters) { $criteria += ('alertDefinition in ' + (@($rule.alertDefinitionIdFilters.values).Count) + ' definition(s)') }

        $records += [pscustomobject]@{
            Name          = $rule.name
            RuleId        = $rule.id
            PluginName    = if ($plugin) { $plugin.name } else { $rule.pluginId }
            PluginType    = if ($plugin) { $plugin.pluginTypeId } else { '' }
            Criteria      = ($criteria -join ' AND ')
            DelayMinutes  = $rule.delay
            NotifyAgain   = $rule.notifyAgain
            MaxNotify     = $rule.maxNotifications
            Enabled       = $rule.isEnabled
        }
    }

    $records = @($records | Sort-Object PluginType, Name)
    Write-Verbose ("Collected {0} notification rule(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    $headers = $null
}
