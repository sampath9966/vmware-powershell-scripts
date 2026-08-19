<#
.SYNOPSIS
    Flattens the whole VCF instance into one row per ESX host, carrying its domain, cluster and commission state.

.DESCRIPTION
    Joins domains, clusters and hosts into a single table so the question 'which host is in
    which cluster in which domain, and what is it running' has one answer in one place -
    including hosts that are commissioned but unassigned, which are the ones that quietly go
    missing from capacity plans.

    Adds the per-host CPU socket and core counts, which is what licensing conversations actually
    need, and the storage type of each cluster so vSAN and non-vSAN clusters are distinguishable
    at a glance.

    Calls GET /v1/domains, GET /v1/clusters and GET /v1/hosts.

    Pain area addressed: #10 Cross-domain inventory.

.PARAMETER Server
    FQDN or IP address of the SDDC Manager appliance.

.PARAMETER Credential
    Credential used to authenticate to SDDC Manager (for example administrator@vsphere.local).

.PARAMETER DomainName
    Limit the inventory to these workload domain names.

.PARAMETER UnassignedOnly
    Return only commissioned hosts that are not assigned to a cluster - the forgotten capacity.

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
    PS> ./Export-SddcFleetInventory.ps1 -Server sddc.example.local -Credential $cred -OutputPath ./fleet.csv

    Writes one row per host across the whole instance.

.EXAMPLE
    PS> ./Export-SddcFleetInventory.ps1 -Server sddc.example.local -Credential $cred | Group-Object Domain | Select-Object Name, Count

    Counts hosts per workload domain.

.EXAMPLE
    PS> ./Export-SddcFleetInventory.ps1 -Server sddc.example.local -Credential $cred | Measure-Object -Property CpuCores -Sum

    Totals physical cores across the instance - the starting point for a core-based licensing
    count.

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
    [Parameter()] [string[]]$DomainName,
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
    Schema        = 'vcf.sddc.fleet-inventory'
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
    # Scope every call in this script to the connection opened above. Without this,
    # PowerCLI cmdlets act on every connected server, which silently mixes inventories
    # when more than one is connected. The hashtable is cloned first because indexing
    # the inherited one would change the caller's session defaults too.
    $PSDefaultParameterValues = $PSDefaultParameterValues.Clone()
    $PSDefaultParameterValues['*:Server'] = $connection

    $records = @()

    $domains  = Invoke-VcfGetDomains
    $clusters = Invoke-VcfGetClusters
    $hosts    = Invoke-VcfGetHosts

    Write-Verbose ("Found {0} domain(s), {1} cluster(s) and {2} host(s)." -f `
        @($domains.Elements).Count, @($clusters.Elements).Count, @($hosts.Elements).Count)

    $domainById  = @{}
    foreach ($domain in @($domains.Elements)) { $domainById[$domain.Id] = $domain }

    $clusterById = @{}
    foreach ($cluster in @($clusters.Elements)) { $clusterById[$cluster.Id] = $cluster }

    foreach ($vmHost in @($hosts.Elements)) {
        $cluster = $null
        if ($vmHost.Cluster.Id) { $cluster = $clusterById[$vmHost.Cluster.Id] }

        $domain = $null
        if ($vmHost.Domain.Id) { $domain = $domainById[$vmHost.Domain.Id] }

        $isUnassigned = (-not $cluster)
        if ($UnassignedOnly -and -not $isUnassigned) { continue }
        if ($DomainName -and (-not $domain -or $domain.Name -notin $DomainName)) { continue }

        $records += [pscustomobject]@{
            HostFqdn       = $vmHost.Fqdn
            HostId         = $vmHost.Id
            EsxVersion     = $vmHost.EsxiVersion
            HostStatus     = $vmHost.Status
            Domain         = if ($domain) { $domain.Name } else { '(unassigned)' }
            DomainType     = if ($domain) { $domain.Type } else { $null }
            Cluster        = if ($cluster) { $cluster.Name } else { '(unassigned)' }
            ClusterStorage = if ($cluster) { $cluster.PrimaryDatastoreType } else { $null }
            NetworkPool    = $vmHost.NetworkPool.Name
            CpuSockets     = $vmHost.CpuSockets
            CpuCores       = $vmHost.CpuCores
            MemoryGB       = if ($vmHost.MemoryCapacity) { [math]::Round([double]$vmHost.MemoryCapacity / 1024, 1) } else { $null }
            Model          = $vmHost.HardwareModel
            Vendor         = $vmHost.HardwareVendor
        }
    }

    $records = @($records | Sort-Object Domain, Cluster, HostFqdn)
    Write-Verbose ("Collected {0} host record(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    if ($connection) { Disconnect-VcfSddcManagerServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
