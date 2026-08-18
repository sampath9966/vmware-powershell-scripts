<#
.SYNOPSIS
    Reports the appliance version and build alongside the release it is capable of deploying.

.DESCRIPTION
    Returns the appliance's own version and build number and the VCF release it deploys, so the
    pairing is explicit before anyone starts.

    Deploying with an appliance a version behind the intended release is a well-known way to
    produce an environment that cannot be upgraded cleanly, and the version is on a login banner
    nobody reads.

    Pain area addressed: #3 BOM / version drift per domain.

.PARAMETER Server
    FQDN or IP address of the VCF Installer appliance.

.PARAMETER Credential
    Credential used to authenticate to the VCF Installer appliance.

.PARAMETER IgnoreInvalidCertificate
    Accept an untrusted or self-signed certificate on the VCF Installer endpoint. Use only in
    lab environments.

.PARAMETER OutputPath
    Path of the file to write. When omitted the records are only returned on the pipeline and
    nothing is written to disk.

.PARAMETER Format
    Output file format. CSV is the flat table, JSON carries the export envelope that the
    matching import script validates, HTML is a styled table for sharing.

.EXAMPLE
    PS> ./Export-InstallerApplianceVersion.ps1 -Server cb.example.local -Credential $cred

    Reports the appliance version and the release it deploys.

.NOTES
    Author        : Sampath
    Product       : VCF Installer (VCF 9.x)
    Target        : VMware Cloud Foundation 9.x
    Modules       : VMware.Sdk.Vcf.Installer
    Behaviour     : Read-only. Collects data and optionally writes it to disk.
    Standalone    : Yes. This script does not dot-source or import any other file
                    in this repository and can be copied out on its own.
#>

#Requires -Version 5.1
#Requires -Modules VMware.Sdk.Vcf.Installer

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Server,
    [Parameter(Mandatory)] [System.Management.Automation.PSCredential]$Credential,
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
    Schema        = 'installer.appliance-version'
    SchemaVersion = '1.0'
    Product       = 'vcf-installer'
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
    $connection = Connect-VcfInstallerServer @connectParams -ErrorAction Stop
    Write-Verbose "Connected to VCF Installer $Server"

    $records = @()

    $about = $null
    try { $about = Invoke-VcfGetInstallerAbout }
    catch { Write-Warning ("Could not read appliance version information: {0}" -f $_.Exception.Message) }

    $records += [pscustomobject]@{
        Appliance      = 'VCF Installer'
        Server         = $Server
        Version        = if ($about) { $about.Version } else { '' }
        Build          = if ($about) { $about.BuildNumber } else { '' }
        DeploysRelease = if ($about) { $about.ReleaseVersion } else { '' }
        CheckedAt      = (Get-Date).ToString('u')
    }

    Write-Verbose ("Collected {0} version record(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    if ($connection) { Disconnect-VcfInstallerServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
