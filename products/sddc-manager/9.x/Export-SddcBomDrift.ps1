<#
.SYNOPSIS
    Compares the running version of every component in every workload domain against the target VCF release BOM.

.DESCRIPTION
    Reads the release each workload domain is currently on, expands its Bill of Materials, and
    lines the running component versions up against the BOM the domain is supposed to match.
    Anything that does not line up comes back marked Drift.

    This is the report people rebuild by hand before every upgrade window, because the answer
    lives in three places at once: the domain release, the BOM of that release, and whatever the
    components actually report. One row per component per domain, with a Drift column, replaces
    that spreadsheet.

    Calls GET /v1/releases, GET /v1/domains and GET /v1/releases/domains/{id}.

    Pain area addressed: #3 BOM / version drift per domain.

.PARAMETER Server
    FQDN or IP address of the SDDC Manager appliance.

.PARAMETER Credential
    Credential used to authenticate to SDDC Manager (for example administrator@vsphere.local).

.PARAMETER DomainName
    Limit the comparison to these workload domain names. Omit to check every domain.

.PARAMETER TargetVersion
    Compare against this VCF release version instead of the version each domain is currently
    assigned. Use this to preview what an upgrade to a specific release would touch.

.PARAMETER DriftOnly
    Return only the components that do not match the target BOM.

.PARAMETER IgnoreInvalidCertificate
    Accept an untrusted or self-signed certificate on the SDDC Manager endpoint. Use only in lab
    environments.

.PARAMETER OutputPath
    Path of the file to write. When omitted the records are only returned on the pipeline and
    nothing is written to disk.

.PARAMETER Format
    Output file format. CSV is the flat table, JSON carries the export envelope that the
    matching import script validates, HTML is a styled table for sharing.

.EXAMPLE
    PS> ./Export-SddcBomDrift.ps1 -Server sddc.example.local -Credential $cred -DriftOnly

    Shows only the components whose running version differs from the BOM of their assigned
    release.

.EXAMPLE
    PS> ./Export-SddcBomDrift.ps1 -Server sddc.example.local -Credential $cred -TargetVersion 5.2.1.0 -OutputPath ./drift.html -Format HTML

    Produces a shareable table of what a move to 5.2.1.0 would change, per domain and component.

.NOTES
    Author        : Sampath
    Product       : SDDC Manager (VCF 9.x)
    Target        : VMware Cloud Foundation 9.x
    Modules       : VMware.Sdk.Vcf.SddcManager
    Behaviour     : Read-only. Collects data and optionally writes it to disk.
    Standalone    : Yes. This script does not dot-source or import any other file
                    in this repository and can be copied out on its own.
#>

#Requires -Version 5.1
#Requires -Modules VMware.Sdk.Vcf.SddcManager

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Server,
    [Parameter(Mandatory)] [System.Management.Automation.PSCredential]$Credential,
    [Parameter()] [string[]]$DomainName,
    [Parameter()] [string]$TargetVersion,
    [Parameter()] [switch]$DriftOnly,
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
    Schema        = 'vcf.sddc.bom-drift'
    SchemaVersion = '1.0'
    Product       = 'sddc-manager'
    VcfVersion    = '9.x'
    Server        = $Server
}

$connection = $null
try {
    $connectParams = @{
        Server   = $Server
        User     = $Credential.UserName
        Password = $Credential.GetNetworkCredential().Password
    }
    if ($IgnoreInvalidCertificate) { $connectParams['IgnoreInvalidCertificate'] = $true }
    $connection = Connect-VcfSddcManagerServer @connectParams -ErrorAction Stop
    Write-Verbose "Connected to SDDC Manager $Server"
    # Scope every call in this script to the connection opened above. Without this,
    # PowerCLI cmdlets act on every connected server, which silently mixes inventories
    # when more than one is connected. The hashtable is cloned first because indexing
    # the inherited one would change the caller's session defaults too.
    $PSDefaultParameterValues = $PSDefaultParameterValues.Clone()
    $PSDefaultParameterValues['*:Server'] = $connection

    $records = @()

    $domains = Invoke-VcfGetDomains
    $releases = Invoke-VcfGetReleases
    Write-Verbose ("Found {0} domain(s) and {1} known release(s)." -f @($domains.Elements).Count, @($releases.Elements).Count)

    foreach ($domain in @($domains.Elements)) {
        if ($DomainName -and $domain.Name -notin $DomainName) { continue }

        $currentRelease = Invoke-VcfGetReleases -DomainId $domain.Id
        $currentVersion = @($currentRelease.Elements)[0].Version

        $targetRelease = if ($TargetVersion) {
            @($releases.Elements | Where-Object { $_.Version -eq $TargetVersion })[0]
        }
        else {
            @($currentRelease.Elements)[0]
        }

        if (-not $targetRelease) {
            Write-Warning "No release found matching '$TargetVersion'. Skipping domain '$($domain.Name)'."
            continue
        }

        Write-Verbose ("Domain '{0}' is on {1}; comparing against BOM of {2}." -f $domain.Name, $currentVersion, $targetRelease.Version)

        foreach ($component in @($targetRelease.Bom)) {
            $running = $null
            switch -Wildcard ($component.Name) {
                'VCENTER*' { $running = @(Invoke-VcfGetVcenters -DomainId $domain.Id).Elements[0].Version }
                'NSX*'     { $running = @(Invoke-VcfGetNsxClusters -DomainId $domain.Id).Elements[0].Version }
                'ESX*'     { $running = (@(Invoke-VcfGetHosts -DomainId $domain.Id).Elements.EsxiVersion | Sort-Object -Unique) -join ', ' }
                'SDDC_MANAGER*' { $running = @($releases.Elements | Where-Object { $_.Version -eq $currentVersion })[0].Version }
                default    { $running = $null }
            }

            $drift = if (-not $running) { 'Unknown' }
                     elseif ($running -eq $component.Version) { 'No' }
                     else { 'Yes' }

            if ($DriftOnly -and $drift -ne 'Yes') { continue }

            $records += [pscustomobject]@{
                Domain          = $domain.Name
                DomainType      = $domain.Type
                DomainRelease   = $currentVersion
                TargetRelease   = $targetRelease.Version
                Component       = $component.Name
                BomVersion      = $component.Version
                RunningVersion  = $running
                Drift           = $drift
            }
        }
    }

    $records = @($records | Sort-Object Domain, Component)
    Write-Verbose ("Collected {0} component row(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    if ($connection) { Disconnect-VcfSddcManagerServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
