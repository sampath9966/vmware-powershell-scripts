<#
.SYNOPSIS
    Returns the underlay and overlay path between a pair of VMs, one row per hop.

.DESCRIPTION
    Asks the platform to compute the path between two VMs and returns each hop in order - the
    device, its type, the interface used and whether the hop is in the overlay or the underlay.

    This is the answer to 'why can these two not talk' and it normally lives in a diagram
    somebody drew once. Having it as data makes it comparable between a working pair and a
    broken one, which is how the difference gets found.

    Pain area addressed: #10 Cross-domain inventory.

.PARAMETER Server
    FQDN or IP address of the VCF Operations for Networks platform appliance.

.PARAMETER Credential
    Credential used to authenticate to the Networks API.

.PARAMETER SourceVm
    Name of the source virtual machine.

.PARAMETER DestinationVm
    Name of the destination virtual machine.

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
    PS> ./Export-NetworksVmPath.ps1 -Server networks.example.local -Credential $cred -SourceVm web01 -DestinationVm db01

    Returns the hop-by-hop path between two VMs.

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
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$SourceVm,
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$DestinationVm,
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
    Schema        = 'networks.vm-path'
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

    function Resolve-VmEntityId {
        param([string]$Name)

        $payload = @{ query = ("vm where name = '{0}'" -f $Name); size = 5 } | ConvertTo-Json
        $response = Invoke-RestMethod @restCommon -Method Post -Uri "$baseUri/api/ni/search" -Headers $headers -Body $payload
        $match = @($response.results) | Select-Object -First 1
        if (-not $match) { throw "No virtual machine named '$Name' is known to this instance." }
        return $match.entity_id
    }

    $sourceId = Resolve-VmEntityId -Name $SourceVm
    $destinationId = Resolve-VmEntityId -Name $DestinationVm
    Write-Verbose ("Resolved '{0}' to {1} and '{2}' to {3}." -f $SourceVm, $sourceId, $DestinationVm, $destinationId)

    $pathPayload = @{
        src = @{ entity_id = $sourceId; entity_type = 'VirtualMachine' }
        dst = @{ entity_id = $destinationId; entity_type = 'VirtualMachine' }
    } | ConvertTo-Json -Depth 6

    $path = Invoke-RestMethod @restCommon -Method Post -Uri "$baseUri/api/ni/infra/path" -Headers $headers -Body $pathPayload

    $hopIndex = 0
    foreach ($hop in @($path.path)) {
        $hopIndex++
        $records += [pscustomobject]@{
            Hop            = $hopIndex
            SourceVm       = $SourceVm
            DestinationVm  = $DestinationVm
            DeviceName     = $hop.entity.name
            DeviceType     = $hop.entity.entity_type
            Interface      = $hop.interface_name
            Layer          = $hop.path_type
            Status         = $hop.status
        }
    }

    if (-not $records) {
        Write-Warning "No path was returned. The two VMs may have no observed connectivity, or a data source may be missing."
    }

    $records = @($records | Sort-Object Hop)
    Write-Verbose ("Collected {0} hop(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    $headers = $null
}
