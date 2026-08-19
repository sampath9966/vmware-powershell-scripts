<#
.SYNOPSIS
    Lists site pairings with the service meshes between them and the services each mesh has enabled.

.DESCRIPTION
    Returns each remote site pairing with its endpoint, version and connection state, then a row
    per service mesh carrying the compute profiles on each side and the services activated on it
    - bulk migration, vMotion, network extension, WAN optimisation.

    Before any migration question can be answered you need to know which mesh is up and what it
    can actually do, and that is three screens deep.

    Pain area addressed: #10 Cross-domain inventory.

.PARAMETER Server
    FQDN or IP address of the HCX Manager at the source site.

.PARAMETER Credential
    Credential used to authenticate to HCX Manager.

.PARAMETER SiteName
    Limit to these remote site names.

.PARAMETER OutputPath
    Path of the file to write. When omitted the records are only returned on the pipeline and
    nothing is written to disk.

.PARAMETER Format
    Output file format. CSV is the flat table, JSON carries the export envelope that the
    matching import script validates, HTML is a styled table for sharing.

.EXAMPLE
    PS> ./Export-HcxSitePairing.ps1 -Server hcx.example.local -Credential $cred -OutputPath ./hcxsites.csv

    Writes the pairing and service mesh layout.

.NOTES
    Author        : Sampath
    Product       : VCF Operations HCX (VCF 9.x)
    Target        : VMware Cloud Foundation 9.x
    Modules       : VMware.VimAutomation.Hcx
    Behaviour     : Read-only. Collects data and optionally writes it to disk.
    Standalone    : Yes. This script does not dot-source or import any other file
                    in this repository and can be copied out on its own.
#>

#Requires -Version 5.1
#Requires -Modules VMware.VimAutomation.Hcx

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Server,
    [Parameter(Mandatory)] [System.Management.Automation.PSCredential]$Credential,
    [Parameter()] [string[]]$SiteName,
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
    Schema        = 'hcx.site-pairing'
    SchemaVersion = '1.0'
    Product       = 'vcf-operations-hcx'
    VcfVersion    = '9.x'
    Server        = $Server
}

$connection = $null
try {
    $connection = Connect-HCXServer -Server $Server -Credential $Credential -ErrorAction Stop
    Write-Verbose "Connected to HCX Manager $($connection.Server)"
    # Scope every call in this script to the connection opened above. Without this,
    # PowerCLI cmdlets act on every connected server, which silently mixes inventories
    # when more than one is connected. The hashtable is cloned first because indexing
    # the inherited one would change the caller's session defaults too.
    $PSDefaultParameterValues = $PSDefaultParameterValues.Clone()
    $PSDefaultParameterValues['*:Server'] = $connection

    $records = @()

    $pairings = @(Get-HCXSitePairing -ErrorAction SilentlyContinue)
    Write-Verbose ("HCX reports {0} site pairing(s)." -f $pairings.Count)

    foreach ($pairing in $pairings) {
        if ($SiteName -and $pairing.RemoteSiteName -notin $SiteName) { continue }

        $records += [pscustomobject]@{
            Kind             = 'Pairing'
            RemoteSite       = $pairing.RemoteSiteName
            RemoteEndpoint   = $pairing.Url
            RemoteVersion    = $pairing.RemoteHcxVersion
            Status           = [string]$pairing.Status
            ServiceMesh      = ''
            SourceProfile    = ''
            RemoteProfile    = ''
            Services         = ''
            MeshState        = ''
        }
    }

    foreach ($mesh in (Get-HCXServiceMesh -ErrorAction SilentlyContinue)) {
        if ($SiteName -and $mesh.SitePairing.RemoteSiteName -notin $SiteName) { continue }

        $services = @()
        foreach ($service in @($mesh.Service)) {
            if ($service.IsActivated) { $services += $service.Name }
        }

        $records += [pscustomobject]@{
            Kind             = 'ServiceMesh'
            RemoteSite       = $mesh.SitePairing.RemoteSiteName
            RemoteEndpoint   = ''
            RemoteVersion    = ''
            Status           = ''
            ServiceMesh      = $mesh.Name
            SourceProfile    = [string]$mesh.SourceComputeProfile
            RemoteProfile    = [string]$mesh.DestinationComputeProfile
            Services         = ($services -join '; ')
            MeshState        = [string]$mesh.State
        }
    }

    $records = @($records | Sort-Object RemoteSite, Kind, ServiceMesh)
    Write-Verbose ("Collected {0} pairing and mesh row(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    if ($connection) { Disconnect-HCXServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
