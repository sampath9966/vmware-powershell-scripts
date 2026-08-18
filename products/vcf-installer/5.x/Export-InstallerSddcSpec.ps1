<#
.SYNOPSIS
    Retrieves the deployment spec of a completed bring-up and flattens its key settings, optionally saving the raw JSON.

.DESCRIPTION
    Pulls the spec the appliance used for a bring-up and returns the settings that matter as a
    table - the domain and cluster names, the DNS and NTP servers, the vCenter, NSX and SDDC
    Manager hostnames, the network pool ranges and the host list - and with -SpecOutputPath
    writes the untouched JSON alongside.

    The spec is the design document that was actually built, and it is routinely lost within a
    week of the deployment. Passwords in the spec are replaced with a marker in both outputs.

    Pain area addressed: #16 Config portability between environments.

.PARAMETER Server
    FQDN or IP address of the Cloud Builder appliance.

.PARAMETER Credential
    Credential used to authenticate to the Cloud Builder appliance (default user 'admin').

.PARAMETER SddcId
    Identifier of the deployment to read. Omit to use the most recent one.

.PARAMETER SpecOutputPath
    Path to write the raw spec JSON to, with password fields masked. Omit to skip the raw copy.

.PARAMETER IgnoreInvalidCertificate
    Accept an untrusted or self-signed certificate on the Cloud Builder endpoint. Use only in
    lab environments.

.PARAMETER OutputPath
    Path of the file to write. When omitted the records are only returned on the pipeline and
    nothing is written to disk.

.PARAMETER Format
    Output file format. CSV is the flat table, JSON carries the export envelope that the
    matching import script validates, HTML is a styled table for sharing.

.EXAMPLE
    PS> ./Export-InstallerSddcSpec.ps1 -Server cb.example.local -Credential $cred -SpecOutputPath ./as-built-spec.json -OutputPath ./as-built.csv

    Recovers the as-built spec as both a summary table and masked JSON.

.NOTES
    Author        : Sampath
    Product       : Cloud Builder (VCF 5.x)
    Target        : VMware Cloud Foundation 5.x
    Modules       : VMware.Sdk.Vcf.CloudBuilder
    Behaviour     : Read-only. Collects data and optionally writes it to disk.
    Standalone    : Yes. This script does not dot-source or import any other file
                    in this repository and can be copied out on its own.
#>

#Requires -Version 5.1
#Requires -Modules VMware.Sdk.Vcf.CloudBuilder

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Server,
    [Parameter(Mandatory)] [System.Management.Automation.PSCredential]$Credential,
    [Parameter()] [string]$SddcId,
    [Parameter()] [string]$SpecOutputPath,
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
    Schema        = 'installer.sddc-spec'
    SchemaVersion = '1.0'
    Product       = 'vcf-installer'
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
    $connection = Connect-VcfCloudBuilderServer @connectParams -ErrorAction Stop
    Write-Verbose "Connected to Cloud Builder $Server"

    $records = @()

    $targetId = $SddcId
    if (-not $targetId) {
        $latest = @((Invoke-VcfGetSddcs).Elements | Sort-Object CreationTimestamp -Descending) | Select-Object -First 1
        if (-not $latest) { throw 'The appliance has no deployments to read a spec from.' }
        $targetId = $latest.Id
        Write-Verbose "No -SddcId given; using the most recent deployment $targetId."
    }

    $deployment = Invoke-VcfGetSddc -Id $targetId
    $spec = $deployment.SddcSpec
    if (-not $spec) { throw "Deployment '$targetId' carries no spec." }

    function Hide-SecretValue {
        param($Node)

        if ($null -eq $Node) { return $null }

        if ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [string]) {
            return @($Node | ForEach-Object { Hide-SecretValue -Node $_ })
        }

        if ($Node -is [psobject] -and $Node.PSObject.Properties.Count -gt 0) {
            $copy = [ordered]@{}
            foreach ($property in $Node.PSObject.Properties) {
                if ($property.Name -match 'password|passphrase|secret|token') { $copy[$property.Name] = '(masked)' }
                else { $copy[$property.Name] = Hide-SecretValue -Node $property.Value }
            }
            return [pscustomobject]$copy
        }

        return $Node
    }

    $records += [pscustomobject]@{
        Setting = 'SddcName';        Value = $spec.SddcId
    }
    $records += [pscustomobject]@{ Setting = 'ManagementDomain'; Value = $spec.ManagementPoolName }
    $records += [pscustomobject]@{ Setting = 'DnsServers';       Value = (@($spec.DnsSpec.NameServer, $spec.DnsSpec.SecondaryNameServer) -join '; ') }
    $records += [pscustomobject]@{ Setting = 'DnsDomain';        Value = $spec.DnsSpec.Subdomain }
    $records += [pscustomobject]@{ Setting = 'NtpServers';       Value = (@($spec.NtpServers) -join '; ') }
    $records += [pscustomobject]@{ Setting = 'VcenterHostname';  Value = $spec.VcenterSpec.VcenterHostname }
    $records += [pscustomobject]@{ Setting = 'NsxManagerVip';    Value = $spec.NsxtSpec.Vip }
    $records += [pscustomobject]@{ Setting = 'NsxManagers';      Value = (@($spec.NsxtSpec.NsxtManagers.Hostname) -join '; ') }
    $records += [pscustomobject]@{ Setting = 'SddcManagerHostname'; Value = $spec.SddcManagerSpec.Hostname }
    $records += [pscustomobject]@{ Setting = 'ClusterName';      Value = $spec.ClusterSpec.ClusterName }
    $records += [pscustomobject]@{ Setting = 'DatastoreType';    Value = if ($spec.VsanSpec) { 'vSAN' } else { 'Other' } }
    $records += [pscustomobject]@{ Setting = 'HostCount';        Value = @($spec.HostSpecs).Count }
    $records += [pscustomobject]@{ Setting = 'Hosts';            Value = (@($spec.HostSpecs.Hostname) -join '; ') }

    foreach ($network in @($spec.NetworkSpecs)) {
        $records += [pscustomobject]@{
            Setting = ('Network:' + $network.NetworkType)
            Value   = ('subnet {0}, vlan {1}, gateway {2}, pool {3}' -f `
                $network.Subnet, $network.VlanId, $network.Gateway,
                ((@($network.IncludeIpAddressRanges | ForEach-Object { '{0}-{1}' -f $_.StartIpAddress, $_.EndIpAddress })) -join ','))
        }
    }

    if ($SpecOutputPath) {
        $masked = Hide-SecretValue -Node $spec
        $parent = Split-Path -Parent $SpecOutputPath
        if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        $masked | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $SpecOutputPath -Encoding UTF8
        Write-Verbose "Wrote the masked spec JSON to $SpecOutputPath."
    }

    Write-Verbose ("Collected {0} spec setting row(s). Passwords are masked in every output." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    if ($connection) { Disconnect-VcfCloudBuilderServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
