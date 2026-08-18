<#
.SYNOPSIS
    Exports the application model - each application, its tiers and the membership rules of each tier.

.DESCRIPTION
    Returns one row per application tier with the membership criteria that populates it and the
    VMs currently matching, so the application model is reviewable as a table rather than a set
    of nested panels.

    The application model is what makes flow data readable, and it is hand-built.
    Import-NetworksApplication.ps1 replays this file into a second instance.

    Pain area addressed: #16 Config portability between environments; #10 Cross-domain
    inventory.

.PARAMETER Server
    FQDN or IP address of the VCF Operations for Networks platform appliance.

.PARAMETER Credential
    Credential used to authenticate to the Networks API.

.PARAMETER ApplicationName
    Limit to these application names.

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
    PS> ./Export-NetworksApplication.ps1 -Server networks.example.local -Credential $cred -OutputPath ./apps.json -Format JSON

    Captures the application and tier model.

.NOTES
    Author        : Sampath
    Product       : VCF Operations for networks (VCF 9.x)
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
    [Parameter()] [string[]]$ApplicationName,
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
    Schema        = 'networks.application'
    SchemaVersion = '1.0'
    Product       = 'vcf-operations-for-networks'
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
    $authBody = @{
        username = $Credential.UserName
        password = $Credential.GetNetworkCredential().Password
        domain   = @{ domain_type = 'LOCAL' }
    } | ConvertTo-Json
    $authResponse = Invoke-RestMethod @restCommon -Method Post -Uri "$baseUri/api/ni/auth/token" -Body $authBody
    $headers = @{ Accept = 'application/json'; Authorization = "NetworkInsight $($authResponse.token)" }
    Write-Verbose "Acquired a Networks API token from $Server"

    $records = @()

    $listing = Invoke-RestMethod @restCommon -Method Get -Uri "$baseUri/api/ni/groups/applications" -Headers $headers
    $applications = @($listing.results)
    Write-Verbose ("The platform reports {0} application(s)." -f $applications.Count)

    foreach ($entry in $applications) {
        $application = $null
        try {
            $application = Invoke-RestMethod @restCommon -Method Get `
                -Uri ('{0}/api/ni/groups/applications/{1}' -f $baseUri, $entry.entity_id) -Headers $headers
        }
        catch { Write-Verbose "Could not read application $($entry.entity_id)." }

        if (-not $application) { continue }
        if ($ApplicationName -and $application.name -notin $ApplicationName) { continue }

        $tiers = @()
        try {
            $tierListing = Invoke-RestMethod @restCommon -Method Get `
                -Uri ('{0}/api/ni/groups/applications/{1}/tiers' -f $baseUri, $entry.entity_id) -Headers $headers
            $tiers = @($tierListing.results)
        }
        catch { Write-Verbose "Could not read tiers for '$($application.name)'." }

        if (-not $tiers) {
            $records += [pscustomobject]@{
                Application = $application.name
                ApplicationId = $entry.entity_id
                Tier = ''
                TierId = ''
                MembershipType = ''
                Criteria = ''
                MemberCount = 0
            }
            continue
        }

        foreach ($tierEntry in $tiers) {
            $tier = $null
            try {
                $tier = Invoke-RestMethod @restCommon -Method Get `
                    -Uri ('{0}/api/ni/groups/applications/{1}/tiers/{2}' -f $baseUri, $entry.entity_id, $tierEntry.entity_id) -Headers $headers
            }
            catch { continue }

            $criteria = @()
            foreach ($filter in @($tier.group_membership_criteria)) {
                switch ($filter.membership_type) {
                    'SearchMembershipCriteria' { $criteria += $filter.search_membership_criteria.entity_type + ': ' + $filter.search_membership_criteria.filter }
                    'VMMembershipCriteria'     { $criteria += 'VMs: ' + (@($filter.vm_membership_criteria.vm_entities).Count) }
                    'IPAddressMembershipCriteria' { $criteria += 'IPs: ' + (@($filter.ip_address_membership_criteria.ip_addresses) -join ',') }
                    default { $criteria += $filter.membership_type }
                }
            }

            $records += [pscustomobject]@{
                Application    = $application.name
                ApplicationId  = $entry.entity_id
                Tier           = $tier.name
                TierId         = $tierEntry.entity_id
                MembershipType = (@($tier.group_membership_criteria.membership_type) -join '; ')
                Criteria       = ($criteria -join ' | ')
                MemberCount    = @($tier.group_membership_criteria).Count
            }
        }
    }

    $records = @($records | Sort-Object Application, Tier)
    Write-Verbose ("Collected {0} application tier row(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    $headers = $null
}
