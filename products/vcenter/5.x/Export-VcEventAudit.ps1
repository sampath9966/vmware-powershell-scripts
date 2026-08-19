<#
.SYNOPSIS
    Extracts a readable audit trail from the vCenter event log - who did what, to which object, when.

.DESCRIPTION
    Pulls events for a time window and reduces them to a flat audit table: timestamp, user,
    event type, target object, and the message. Optional filters narrow it to the change-shaped
    events people actually get asked about - power operations, reconfigure, delete, permission
    changes and logins.

    The event view in the UI cannot be exported usefully and pages badly over long windows. This
    chunks the query by day so a month-long window does not time out or blow up memory.

    Pain area addressed: #13 Alarm noise and audit-trail extraction.

.PARAMETER Server
    FQDN or IP address of the vCenter Server to connect to.

.PARAMETER Credential
    Credential used to authenticate to vCenter Server.

.PARAMETER Days
    How many days back to collect. Defaults to 7.

.PARAMETER Username
    Limit to events raised by these users.

.PARAMETER EventCategory
    Limit to these categories: info, warning, error or user.

.PARAMETER ChangesOnly
    Return only change-shaped events - create, delete, reconfigure, power, permission and role
    changes.

.PARAMETER OutputPath
    Path of the file to write. When omitted the records are only returned on the pipeline and
    nothing is written to disk.

.PARAMETER Format
    Output file format. CSV is the flat table, JSON carries the export envelope that the
    matching import script validates, HTML is a styled table for sharing.

.EXAMPLE
    PS> ./Export-VcEventAudit.ps1 -Server vcenter.example.local -Credential $cred -Days 30 -ChangesOnly -OutputPath ./audit.csv

    Extracts a month of change events for a review.

.EXAMPLE
    PS> ./Export-VcEventAudit.ps1 -Server vcenter.example.local -Credential $cred -Days 1 | Group-Object Username | Sort-Object Count -Descending

    Shows who was busiest in the last day.

.NOTES
    Author        : Sampath
    Product       : vCenter Server (VCF 5.x)
    Target        : VMware Cloud Foundation 5.x
    Modules       : VMware.VimAutomation.Core
    Behaviour     : Read-only. Collects data and optionally writes it to disk.
    Standalone    : Yes. This script does not dot-source or import any other file
                    in this repository and can be copied out on its own.
#>

#Requires -Version 5.1
#Requires -Modules VMware.VimAutomation.Core

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Server,
    [Parameter(Mandatory)] [System.Management.Automation.PSCredential]$Credential,
    [Parameter()] [int]$Days = 7,
    [Parameter()] [string[]]$Username,
    [Parameter()] [string[]]$EventCategory,
    [Parameter()] [switch]$ChangesOnly,
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
    Schema        = 'vcenter.event-audit'
    SchemaVersion = '1.0'
    Product       = 'vcenter'
    VcfVersion    = '5.x'
    Server        = $Server
}

$connection = $null
try {
    $connection = Connect-VIServer -Server $Server -Credential $Credential -ErrorAction Stop
    Write-Verbose "Connected to vCenter Server $($connection.Name) (version $($connection.Version))"

    $records = @()

    $changePattern = 'Created|Removed|Deleted|Reconfigur|PoweredOn|PoweredOff|Reset|Suspend|Migrat|Renamed|Permission|Role|Destroy'

    $end = Get-Date
    $start = $end.AddDays(-$Days)
    Write-Verbose ("Collecting events from {0:u} to {1:u}, one day at a time." -f $start, $end)

    $cursor = $start
    while ($cursor -lt $end) {
        $chunkEnd = $cursor.AddDays(1)
        if ($chunkEnd -gt $end) { $chunkEnd = $end }

        $eventParams = @{ Start = $cursor; Finish = $chunkEnd; MaxSamples = [int]::MaxValue }
        if ($Username) { $eventParams['Username'] = $Username }
        if ($EventCategory) { $eventParams['Category'] = $EventCategory }

        foreach ($viEvent in (Get-VIEvent @eventParams)) {
            $type = $viEvent.GetType().Name

            if ($ChangesOnly -and $type -notmatch $changePattern) { continue }

            $records += [pscustomobject]@{
                CreatedTime = $viEvent.CreatedTime
                Username    = $viEvent.UserName
                EventType   = $type
                Datacenter  = $viEvent.Datacenter.Name
                ComputeResource = $viEvent.ComputeResource.Name
                Host        = $viEvent.Host.Name
                VM          = $viEvent.Vm.Name
                Message     = ($viEvent.FullFormattedMessage -replace '\s+', ' ')
                ChainId     = $viEvent.ChainId
            }
        }

        Write-Verbose ("  {0:yyyy-MM-dd}: running total {1}" -f $cursor, $records.Count)
        $cursor = $chunkEnd
    }

    $records = @($records | Sort-Object CreatedTime -Descending)
    Write-Verbose ("Collected {0} event(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    if ($connection) { Disconnect-VIServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
