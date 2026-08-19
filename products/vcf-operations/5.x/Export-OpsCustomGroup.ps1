<#
.SYNOPSIS
    Exports custom groups with their membership rules, policy assignment and current member count.

.DESCRIPTION
    Returns each custom group with the group type it belongs to, the policy applied to it,
    whether membership is dynamic, the rule expressions that define it, and how many resources
    currently resolve into it.

    A dynamic group with zero members is a policy that is not being applied to anything, and
    nothing surfaces that. Filtering this to MemberCount -eq 0 finds them.

    Pain area addressed: #16 Config portability between environments; #10 Cross-domain
    inventory.

.PARAMETER Server
    FQDN or IP address of the VCF Operations node.

.PARAMETER Credential
    Credential used to authenticate to the VCF Operations API.

.PARAMETER GroupName
    Limit to these group names.

.PARAMETER EmptyOnly
    Return only groups that currently resolve to no members.

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
    PS> ./Export-OpsCustomGroup.ps1 -Server ops.example.local -Credential $cred -EmptyOnly

    Finds custom groups whose membership rules match nothing.

.NOTES
    Author        : Sampath
    Product       : Aria Operations (VCF 5.x)
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
    [Parameter()] [string[]]$GroupName,
    [Parameter()] [switch]$EmptyOnly,
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
    Schema        = 'vcf-operations.custom-group'
    SchemaVersion = '1.0'
    Product       = 'vcf-operations'
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
    $authBody = @{ username = $Credential.UserName; password = $Credential.GetNetworkCredential().Password } | ConvertTo-Json
    $authResponse = Invoke-RestMethod @restCommon -Method Post -Uri "$baseUri/suite-api/api/auth/token/acquire" -Headers @{ Accept = 'application/json' } -Body $authBody
    $headers = @{ Accept = 'application/json'; Authorization = "vRealizeOpsToken $($authResponse.token)" }
    Write-Verbose "Acquired a VCF Operations API token from $Server"

    $records = @()

    $response = Invoke-RestMethod @restCommon -Method Get -Uri "$baseUri/suite-api/api/resources/groups" -Headers $headers
    $groups = @($response.groups)
    Write-Verbose ("Operations reports {0} custom group(s)." -f $groups.Count)

    foreach ($group in $groups) {
        if ($GroupName -and $group.resourceKey.name -notin $GroupName) { continue }

        $memberCount = 0
        try {
            $members = Invoke-RestMethod @restCommon -Method Get `
                -Uri ('{0}/suite-api/api/resources/groups/{1}/members' -f $baseUri, $group.id) -Headers $headers
            $memberCount = @($members.resourceList).Count
        }
        catch { Write-Verbose "Could not read members of group '$($group.resourceKey.name)'." }

        if ($EmptyOnly -and $memberCount -gt 0) { continue }

        $rules = @()
        foreach ($rule in @($group.membershipDefinition.rules)) {
            foreach ($condition in @($rule.resourceNameConditionRules)) {
                $rules += ('name {0} "{1}"' -f $condition.compareOperator, $condition.name)
            }
            foreach ($condition in @($rule.propertyConditionRules)) {
                $rules += ('{0} {1} "{2}"' -f $condition.key, $condition.compareOperator, $condition.stringValue)
            }
            foreach ($condition in @($rule.statConditionRules)) {
                $rules += ('{0} {1} {2}' -f $condition.key, $condition.compareOperator, $condition.doubleValue)
            }
        }

        $records += [pscustomobject]@{
            Name             = $group.resourceKey.name
            GroupId          = $group.id
            GroupType        = $group.resourceKey.resourceKindKey
            Policy           = $group.policy
            AutoResolve      = $group.autoResolveMembership
            Rules            = ($rules -join ' AND ')
            RuleCount        = @($rules).Count
            StaticMembers    = @($group.membershipDefinition.includedResources).Count
            MemberCount      = $memberCount
        }
    }

    $records = @($records | Sort-Object Name)
    Write-Verbose ("Collected {0} custom group(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    $headers = $null
}
