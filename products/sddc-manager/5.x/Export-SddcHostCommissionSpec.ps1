<#
.SYNOPSIS
    Exports the commissioned hosts as a commission spec that Import-SddcHostCommission.ps1 can replay elsewhere.

.DESCRIPTION
    Turns the hosts SDDC Manager already knows about into the shape a commission request expects
    - FQDN, network pool, storage type - so a second instance, a rebuild or a DR site can be
    brought to the same starting point without retyping every host.

    Passwords are never exported. The generated file carries a HostPassword column that is
    deliberately left empty for you to fill in, or to supply at import time from a credential
    store.

    Calls GET /v1/hosts and GET /v1/network-pools.

    Pain area addressed: #10 Cross-domain inventory; #16 Config portability between
    environments.

.PARAMETER Server
    FQDN or IP address of the SDDC Manager appliance.

.PARAMETER Credential
    Credential used to authenticate to SDDC Manager (for example administrator@vsphere.local).

.PARAMETER UnassignedOnly
    Export only hosts that are commissioned but not yet assigned to a cluster.

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
    PS> ./Export-SddcHostCommissionSpec.ps1 -Server sddc.example.local -Credential $cred -OutputPath ./hosts.json -Format JSON

    Writes a commission spec covering every commissioned host.

.NOTES
    Author        : Sampath
    Product       : SDDC Manager (VCF 5.x)
    Target        : VMware Cloud Foundation 5.x
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
    [Parameter()] [switch]$UnassignedOnly,
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
    Schema        = 'vcf.sddc.host-commission-spec'
    SchemaVersion = '1.0'
    Product       = 'sddc-manager'
    VcfVersion    = '5.x'
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

    $records = @()

    $hosts = Invoke-VcfGetHosts
    $networkPools = Invoke-VcfGetNetworkPools
    Write-Verbose ("Found {0} host(s) and {1} network pool(s)." -f @($hosts.Elements).Count, @($networkPools.Elements).Count)

    foreach ($vmHost in @($hosts.Elements)) {
        if ($UnassignedOnly -and $vmHost.Cluster.Id) { continue }

        $poolName = $vmHost.NetworkPool.Name
        if (-not $poolName -and $vmHost.NetworkPool.Id) {
            $poolName = @($networkPools.Elements | Where-Object { $_.Id -eq $vmHost.NetworkPool.Id })[0].Name
        }

        $records += [pscustomobject]@{
            HostFqdn        = $vmHost.Fqdn
            Username        = 'root'
            HostPassword    = ''
            NetworkPoolName = $poolName
            StorageType     = $vmHost.StorageType
            VvolStorageProtocolType = $vmHost.VvolStorageProtocolType
            CurrentStatus   = $vmHost.Status
        }
    }

    $records = @($records | Sort-Object HostFqdn)
    Write-Verbose ("Collected {0} host spec record(s). HostPassword is intentionally blank." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    if ($connection) { Disconnect-VcfSddcManagerServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
