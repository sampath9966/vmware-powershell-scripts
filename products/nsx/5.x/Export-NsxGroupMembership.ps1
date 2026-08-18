<#
.SYNOPSIS
    Resolves every security group to its effective VM membership, alongside the criteria that produced it.

.DESCRIPTION
    For each group: the membership criteria as configured - tag expressions, name patterns,
    static members - and then the effective members NSX has actually computed, one row per VM.

    Dynamic membership is the thing people get wrong and cannot verify. A tag typo produces an
    empty group and a rule that silently protects nothing. This puts the intent and the reality
    next to each other, which is the only way to spot that.

    Pain area addressed: #8 DFW rules and effective membership; #10 Cross-domain inventory.

.PARAMETER Server
    FQDN or IP address of the NSX Manager to connect to.

.PARAMETER Credential
    Credential used to authenticate to NSX Manager.

.PARAMETER Domain
    Policy domain to read. Defaults to 'default'.

.PARAMETER GroupName
    Limit to these group names.

.PARAMETER EmptyOnly
    Return only groups whose effective membership is empty - the likely typos.

.PARAMETER OutputPath
    Path of the file to write. When omitted the records are only returned on the pipeline and
    nothing is written to disk.

.PARAMETER Format
    Output file format. CSV is the flat table, JSON carries the export envelope that the
    matching import script validates, HTML is a styled table for sharing.

.EXAMPLE
    PS> ./Export-NsxGroupMembership.ps1 -Server nsx.example.local -Credential $cred -EmptyOnly

    Finds groups that resolve to nothing, usually a tag that does not match.

.EXAMPLE
    PS> ./Export-NsxGroupMembership.ps1 -Server nsx.example.local -Credential $cred | Where-Object VmName -eq 'web01'

    Answers 'which groups is this VM actually in'.

.NOTES
    Author        : Sampath
    Product       : NSX-T Data Center (VCF 5.x)
    Target        : VMware Cloud Foundation 5.x
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
    [Parameter()] [string[]]$GroupName,
    [Parameter()] [switch]$EmptyOnly,
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
    Schema        = 'nsx.group-membership'
    SchemaVersion = '1.0'
    Product       = 'nsx'
    VcfVersion    = '5.x'
    Server        = $Server
}

$connection = $null
try {
    $connection = Connect-NsxtServer -Server $Server -Credential $Credential -ErrorAction Stop
    Write-Verbose "Connected to NSX Manager $($connection.Name)"

    $records = @()

    $groupService = Get-NsxtPolicyService -Name 'com.vmware.nsx_policy.infra.domains.groups'
    $memberService = Get-NsxtPolicyService -Name 'com.vmware.nsx_policy.infra.domains.groups.members.virtual_machines'

    $groups = @($groupService.list($Domain).results)
    if ($GroupName) { $groups = @($groups | Where-Object { $_.display_name -in $GroupName }) }
    Write-Verbose ("Found {0} group(s) in domain '{1}'." -f $groups.Count, $Domain)

    foreach ($group in $groups) {
        $criteria = @()
        foreach ($expression in @($group.expression)) {
            switch ($expression.resource_type) {
                'Condition' {
                    $criteria += ('{0}.{1} {2} "{3}"' -f $expression.member_type, $expression.key, $expression.operator, $expression.value)
                }
                'ConjunctionOperator' { $criteria += $expression.conjunction_operator }
                'NestedExpression'    { $criteria += '(nested expression)' }
                'IPAddressExpression' { $criteria += ('IPs: ' + ($expression.ip_addresses -join ',')) }
                'PathExpression'      { $criteria += ('Static: ' + (($expression.paths | ForEach-Object { ($_ -split '/')[-1] }) -join ',')) }
                default               { $criteria += $expression.resource_type }
            }
        }

        $members = @()
        try { $members = @($memberService.list($Domain, $group.id).results) }
        catch { Write-Warning ("Could not resolve members of '{0}': {1}" -f $group.display_name, $_.Exception.Message) }

        if ($EmptyOnly -and $members.Count -gt 0) { continue }

        if (-not $members) {
            $records += [pscustomobject]@{
                Group       = $group.display_name
                GroupId     = $group.id
                Criteria    = ($criteria -join ' ')
                MemberCount = 0
                VmName      = ''
                VmId        = ''
                VmTags      = ''
            }
            continue
        }

        foreach ($member in $members) {
            $tags = @()
            foreach ($tag in @($member.tags)) { $tags += ('{0}={1}' -f $tag.scope, $tag.tag) }

            $records += [pscustomobject]@{
                Group       = $group.display_name
                GroupId     = $group.id
                Criteria    = ($criteria -join ' ')
                MemberCount = $members.Count
                VmName      = $member.display_name
                VmId        = $member.external_id
                VmTags      = ($tags -join '; ')
            }
        }
    }

    $records = @($records | Sort-Object Group, VmName)
    Write-Verbose ("Collected {0} membership row(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    if ($connection) { Disconnect-NsxtServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
