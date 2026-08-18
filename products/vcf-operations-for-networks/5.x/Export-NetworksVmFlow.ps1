<#
.SYNOPSIS
    Pulls observed VM-to-VM traffic flows for a time window, aggregated into a source, destination and port table.

.DESCRIPTION
    Runs a flow search for the window you give it and returns one row per source VM, destination
    VM, port and protocol combination, with the byte and session totals - which is exactly the
    shape a firewall rule set is written from.

    This is the artefact microsegmentation projects are built on and the one that normally gets
    assembled by screenshotting the flow view. Filter by -VmName to scope it to one application
    before you write its policy.

    Pain area addressed: #8 DFW rules and effective membership.

.PARAMETER Server
    FQDN or IP address of the VCF Operations for Networks platform appliance.

.PARAMETER Credential
    Credential used to authenticate to the Networks API.

.PARAMETER Hours
    How many hours of flow history to query. Defaults to 24.

.PARAMETER VmName
    Limit to flows where one side is one of these VMs. Strongly recommended - unfiltered flow
    queries are large and slow.

.PARAMETER MaxResults
    Stop after this many flow records. Defaults to 5000.

.PARAMETER PageSize
    How many records to request per call. Defaults to 100.

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
    PS> ./Export-NetworksVmFlow.ps1 -Server networks.example.local -Credential $cred -VmName web01,app01 -Hours 168 -OutputPath ./flows.csv

    Pulls a week of traffic for two VMs, ready to turn into rules.

.NOTES
    Author        : Sampath
    Product       : Aria Operations for Networks (VCF 5.x)
    Target        : VMware Cloud Foundation 5.x
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
    [Parameter()] [int]$Hours = 24,
    [Parameter()] [string[]]$VmName,
    [Parameter()] [int]$MaxResults = 5000,
    [Parameter()] [int]$PageSize = 100,
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
    Schema        = 'networks.vm-flow'
    SchemaVersion = '1.0'
    Product       = 'vcf-operations-for-networks'
    VcfVersion    = '5.x'
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

    $endTime = [int][double]::Parse((Get-Date -UFormat %s))
    $startTime = $endTime - ($Hours * 3600)

    $query = 'flow'
    if ($VmName) {
        $names = @($VmName | ForEach-Object { "'" + $_ + "'" }) -join ', '
        $query = "flow where source vm in ($names) or destination vm in ($names)"
    }
    Write-Verbose ("Flow query: {0}" -f $query)

    $cursor = $null
    $collected = 0

    do {
        $payload = @{
            query = $query
            size  = $PageSize
            time_range = @{ start_time = $startTime; end_time = $endTime }
        }
        if ($cursor) { $payload['cursor'] = $cursor }

        $response = $null
        try {
            $response = Invoke-RestMethod @restCommon -Method Post -Uri "$baseUri/api/ni/search" `
                -Headers $headers -Body ($payload | ConvertTo-Json -Depth 6)
        }
        catch {
            Write-Warning ("Flow search failed: {0}" -f $_.Exception.Message)
            break
        }

        $entities = @($response.results)
        if (-not $entities) { break }

        $ids = @($entities.entity_id)
        if ($ids) {
            $detailPayload = @{ entity_ids = $ids } | ConvertTo-Json -Depth 4
            $details = $null
            try {
                $details = Invoke-RestMethod @restCommon -Method Post -Uri "$baseUri/api/ni/entities/fetch" `
                    -Headers $headers -Body $detailPayload
            }
            catch { Write-Verbose 'Could not fetch flow detail for this page.' }

            foreach ($flow in @($details.results)) {
                $entity = $flow.entity
                $records += [pscustomobject]@{
                    SourceVm       = $entity.source_vm.name
                    SourceIp       = $entity.source_ip.ip_address
                    DestinationVm  = $entity.destination_vm.name
                    DestinationIp  = $entity.destination_ip.ip_address
                    Port           = $entity.port.iana_port_display
                    PortNumber     = $entity.port.start
                    Protocol       = $entity.protocol
                    FlowType       = $entity.flow_type
                    FirewallAction = $entity.firewall_action
                    TotalBytes     = $entity.totalBytes.total
                    TotalSessions  = $entity.totalSessionCount.total
                }
                $collected++
            }
        }

        $cursor = $response.cursor
        Write-Verbose ("  collected {0} flow record(s) so far" -f $collected)
        Start-Sleep -Milliseconds 250
    } while ($cursor -and $collected -lt $MaxResults)

    $records = @($records | Sort-Object SourceVm, DestinationVm, PortNumber)
    Write-Verbose ("Collected {0} flow record(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    $headers = $null
}
