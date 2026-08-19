<#
.SYNOPSIS
    Exports every distributed firewall policy and rule into one flat table with sources, destinations, services and scope resolved to names.

.DESCRIPTION
    Walks every security policy in the domain and every rule inside it, returning one row per
    rule with its category, sequence, action, direction, IP protocol, and the source,
    destination, service and applied-to lists resolved from policy paths to readable names.

    The path-to-name resolution is what makes this usable: the raw API returns
    '/infra/domains/default/groups/web-tier' where a human needs 'web-tier'. Auditors ask for
    this table, change reviews need it, and the UI cannot produce it.

    Pain area addressed: #8 DFW rules and effective membership.

.PARAMETER Server
    FQDN or IP address of the NSX Manager to connect to.

.PARAMETER Credential
    Credential used to authenticate to NSX Manager.

.PARAMETER Domain
    Policy domain to read. Defaults to 'default'.

.PARAMETER Category
    Limit to these rule categories, for example Ethernet, Emergency, Infrastructure, Environment
    or Application.

.PARAMETER IncludeDisabled
    Include rules that are currently disabled.

.PARAMETER OutputPath
    Path of the file to write. When omitted the records are only returned on the pipeline and
    nothing is written to disk.

.PARAMETER Format
    Output file format. CSV is the flat table, JSON carries the export envelope that the
    matching import script validates, HTML is a styled table for sharing.

.EXAMPLE
    PS> ./Export-NsxDfwRule.ps1 -Server nsx.example.local -Credential $cred -OutputPath ./dfw.json -Format JSON

    Exports the whole rule base in the envelope Import-NsxDfwRule.ps1 consumes.

.EXAMPLE
    PS> ./Export-NsxDfwRule.ps1 -Server nsx.example.local -Credential $cred | Where-Object { $_.Action -eq 'ALLOW' -and $_.Destination -eq 'ANY' }

    Finds allow-any rules - the first thing a firewall review looks for.

.NOTES
    Author        : Sampath
    Product       : NSX (including vDefend) (VCF 9.x)
    Target        : VMware Cloud Foundation 9.x
    Modules       : VMware.VimAutomation.Nsxt
    Behaviour     : Read-only. Collects data and optionally writes it to disk.
    Standalone    : Yes. This script does not dot-source or import any other file
                    in this repository and can be copied out on its own.
#>

#Requires -Version 5.1
#Requires -Modules VMware.VimAutomation.Nsxt

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Server,
    [Parameter(Mandatory)] [System.Management.Automation.PSCredential]$Credential,
    [Parameter()] [string]$Domain = 'default',
    [Parameter()] [string[]]$Category,
    [Parameter()] [switch]$IncludeDisabled,
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
    Schema        = 'nsx.dfw-rule'
    SchemaVersion = '1.0'
    Product       = 'nsx'
    VcfVersion    = '9.x'
    Server        = $Server
}

$connection = $null
try {
    $connection = Connect-NsxtServer -Server $Server -Credential $Credential -ErrorAction Stop
    Write-Verbose "Connected to NSX Manager $($connection.Name)"
    # Scope every call in this script to the connection opened above. Without this,
    # PowerCLI cmdlets act on every connected server, which silently mixes inventories
    # when more than one is connected. The hashtable is cloned first because indexing
    # the inherited one would change the caller's session defaults too.
    $PSDefaultParameterValues = $PSDefaultParameterValues.Clone()
    $PSDefaultParameterValues['*:Server'] = $connection

    $records = @()

    $policyService = Get-NsxtPolicyService -Name 'com.vmware.nsx_policy.infra.domains.security_policies'
    $ruleService = Get-NsxtPolicyService -Name 'com.vmware.nsx_policy.infra.domains.security_policies.rules'
    $groupService = Get-NsxtPolicyService -Name 'com.vmware.nsx_policy.infra.domains.groups'
    $serviceService = Get-NsxtPolicyService -Name 'com.vmware.nsx_policy.infra.services'

    $nameByPath = @{}
    foreach ($group in @($groupService.list($Domain).results)) { $nameByPath[$group.path] = $group.display_name }
    foreach ($service in @($serviceService.list().results)) { $nameByPath[$service.path] = $service.display_name }
    Write-Verbose ("Resolved {0} group and service path(s) to names." -f $nameByPath.Count)

    function Resolve-PathList {
        param([object[]]$Path)

        if (-not $Path) { return '' }
        $names = foreach ($entry in $Path) {
            if ($entry -eq 'ANY') { 'ANY' }
            elseif ($nameByPath.ContainsKey($entry)) { $nameByPath[$entry] }
            else { ($entry -split '/')[-1] }
        }
        return ($names -join '; ')
    }

    $policies = @($policyService.list($Domain).results)
    Write-Verbose ("Found {0} security policy/policies in domain '{1}'." -f $policies.Count, $Domain)

    foreach ($policy in $policies) {
        if ($Category -and $policy.category -notin $Category) { continue }

        foreach ($rule in @($ruleService.list($Domain, $policy.id).results)) {
            if (-not $IncludeDisabled -and $rule.disabled) { continue }

            $records += [pscustomobject]@{
                Policy          = $policy.display_name
                PolicyId        = $policy.id
                Category        = $policy.category
                PolicySequence  = $policy.sequence_number
                Stateful        = $policy.stateful
                RuleName        = $rule.display_name
                RuleId          = $rule.id
                Sequence        = $rule.sequence_number
                Action          = $rule.action
                Direction       = $rule.direction
                IpProtocol      = $rule.ip_protocol
                Source          = Resolve-PathList -Path $rule.source_groups
                SourceNegated   = $rule.sources_excluded
                Destination     = Resolve-PathList -Path $rule.destination_groups
                DestNegated     = $rule.destinations_excluded
                Service         = Resolve-PathList -Path $rule.services
                AppliedTo       = Resolve-PathList -Path $rule.scope
                Disabled        = $rule.disabled
                Logged          = $rule.logged
                Notes           = $rule.notes
            }
        }
    }

    $records = @($records | Sort-Object Category, PolicySequence, Sequence)
    Write-Verbose ("Collected {0} firewall rule(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    if ($connection) { Disconnect-NsxtServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
