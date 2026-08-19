<#
.SYNOPSIS
    Lists every upgrade and patch bundle SDDC Manager knows about, with size, applicability and download state.

.DESCRIPTION
    Reports which bundles exist, which are already downloaded, which are only partially
    downloaded, and how much disk each one wants - alongside the components and releases each
    bundle applies to.

    Before an upgrade window the question is always 'is everything staged', and the UI answers
    it one tile at a time. This gives the whole staging picture in one table, including the
    bundles that are downloadable but nobody has pulled yet.

    Calls GET /v1/bundles.

    Pain area addressed: #12 Upgrade prechecks and bundle state.

.PARAMETER Server
    FQDN or IP address of the SDDC Manager appliance.

.PARAMETER Credential
    Credential used to authenticate to SDDC Manager (for example administrator@vsphere.local).

.PARAMETER BundleType
    Limit to these bundle types, for example INSTALL, PATCH or DRIVER.

.PARAMETER NotDownloadedOnly
    Return only bundles that are not yet fully downloaded - the staging gap list.

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
    PS> ./Export-SddcBundleInventory.ps1 -Server sddc.example.local -Credential $cred -NotDownloadedOnly -OutputPath ./bundles.json -Format JSON

    Writes the bundles still to be staged, ready to feed straight into
    Invoke-SddcBundleDownload.ps1.

.EXAMPLE
    PS> ./Export-SddcBundleInventory.ps1 -Server sddc.example.local -Credential $cred | Measure-Object -Property SizeMB -Sum

    Totals the disk that all known bundles occupy.

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
    [Parameter()] [string[]]$BundleType,
    [Parameter()] [switch]$NotDownloadedOnly,
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
    Schema        = 'vcf.sddc.bundle-inventory'
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

    $bundles = Invoke-VcfGetBundles
    Write-Verbose ("SDDC Manager knows about {0} bundle(s)." -f @($bundles.Elements).Count)

    foreach ($bundle in @($bundles.Elements)) {
        if ($BundleType -and $bundle.Type -notin $BundleType) { continue }

        $downloadStatus = $bundle.DownloadStatus
        if ($NotDownloadedOnly -and $downloadStatus -eq 'SUCCESSFUL') { continue }

        $sizeMb = $null
        if ($bundle.SizeMB) { $sizeMb = [math]::Round([double]$bundle.SizeMB, 1) }

        $applicableTo = @()
        foreach ($component in @($bundle.Components)) {
            $applicableTo += ('{0} {1}->{2}' -f $component.Type, $component.FromVersion, $component.ToVersion)
        }

        $records += [pscustomobject]@{
            BundleId       = $bundle.Id
            Type           = $bundle.Type
            Severity       = $bundle.Severity
            Vendor         = $bundle.Vendor
            Version        = $bundle.Version
            Description    = $bundle.Description
            SizeMB         = $sizeMb
            DownloadStatus = $downloadStatus
            IsCumulative   = $bundle.IsCumulative
            ReleasedDate   = $bundle.ReleasedDate
            AppliesTo      = $applicableTo -join '; '
        }
    }

    $records = @($records | Sort-Object DownloadStatus, ReleasedDate)
    Write-Verbose ("Collected {0} bundle record(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    if ($connection) { Disconnect-VcfSddcManagerServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
