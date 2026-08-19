<#
.SYNOPSIS
    Reports the last sync of every directory with its outcome, duration and how many objects changed.

.DESCRIPTION
    Returns each directory with the timestamp and result of its last sync, how long it took, how
    many users and groups were added, updated or removed, and how many hours have passed since -
    flagged against the schedule it is supposed to keep.

    A directory that stopped syncing does not fail loudly: people who left keep working and new
    joiners cannot log in, and both get blamed on something else for a week. Sorting by
    HoursSinceSync answers it immediately.

    Pain area addressed: #9 Config drift (NTP/DNS/syslog/lockdown).

.PARAMETER Server
    FQDN or IP address of the VCF Identity Broker appliance.

.PARAMETER Credential
    Credential used to authenticate to the Identity Broker API.

.PARAMETER StaleHours
    Hours since the last sync before a directory is treated as stale. Defaults to 24.

.PARAMETER StaleOnly
    Return only directories that are stale or whose last sync failed.

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
    PS> ./Export-IdentitySyncStatus.ps1 -Server idb.example.local -Credential $cred -StaleOnly

    Lists directories that have stopped syncing or failed their last run.

.NOTES
    Author        : Sampath
    Product       : VCF Identity Broker (VCF 9.x)
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
    [Parameter()] [int]$StaleHours = 24,
    [Parameter()] [switch]$StaleOnly,
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
    Schema        = 'identity.sync-status'
    SchemaVersion = '1.0'
    Product       = 'vcf-identity-broker'
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
    $authBody = @{ username = $Credential.UserName; password = $Credential.GetNetworkCredential().Password; issueToken = $true } | ConvertTo-Json
    $authResponse = Invoke-RestMethod @restCommon -Method Post -Uri "$baseUri/SAAS/API/1.0/REST/auth/system/login" -Body $authBody
    $headers = @{ Accept = 'application/json'; Authorization = "HZN $($authResponse.sessionToken)" }
    Write-Verbose "Acquired an Identity Broker session token from $Server"

    $records = @()

    $response = Invoke-RestMethod @restCommon -Method Get `
        -Uri "$baseUri/SAAS/jersey/manager/api/connectormanagement/directoryconfigs" -Headers $headers
    $directories = @($response.items)
    Write-Verbose ("Checking sync state for {0} directory/directories." -f $directories.Count)

    foreach ($directory in $directories) {
        $sync = $null
        try {
            $sync = Invoke-RestMethod @restCommon -Method Get `
                -Uri ('{0}/SAAS/jersey/manager/api/connectormanagement/directoryconfigs/{1}/syncprofile' -f $baseUri, $directory.directoryId) `
                -Headers $headers
        }
        catch { Write-Verbose "Could not read the sync profile for '$($directory.name)'." }

        $lastSync = $null
        if ($sync -and $sync.lastSyncTime) {
            try { $lastSync = [datetimeoffset]::FromUnixTimeMilliseconds([int64]$sync.lastSyncTime).UtcDateTime }
            catch { $lastSync = $null }
        }

        $hoursSince = $null
        if ($lastSync) { $hoursSince = [int][math]::Floor(((Get-Date).ToUniversalTime() - $lastSync).TotalHours) }

        $result = if ($sync) { $sync.lastSyncStatus } else { 'Unknown' }
        $stale = ($null -eq $hoursSince) -or ($hoursSince -ge $StaleHours) -or ($result -notin @('SUCCESS', 'COMPLETED'))

        if ($StaleOnly -and -not $stale) { continue }

        $records += [pscustomobject]@{
            Directory       = $directory.name
            DirectoryId     = $directory.directoryId
            Type            = $directory.type
            LastSync        = if ($lastSync) { $lastSync.ToString('u') } else { '' }
            HoursSinceSync  = $hoursSince
            LastSyncResult  = $result
            UsersAdded      = if ($sync) { $sync.usersAdded } else { $null }
            UsersUpdated    = if ($sync) { $sync.usersUpdated } else { $null }
            UsersRemoved    = if ($sync) { $sync.usersRemoved } else { $null }
            GroupsAdded     = if ($sync) { $sync.groupsAdded } else { $null }
            CurrentUsers    = $directory.userCount
            CurrentGroups   = $directory.groupCount
            Stale           = $stale
        }
    }

    $records = @($records | Sort-Object Stale -Descending)
    Write-Verbose ("Collected {0} directory sync record(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    $headers = $null
}
