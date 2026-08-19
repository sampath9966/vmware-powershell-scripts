<#
.SYNOPSIS
    Lists every migration with its type, state, progress percentage and the error where one has occurred.

.DESCRIPTION
    Returns one row per migration carrying the VM, migration type, source and destination site,
    the current state and progress, the scheduled switchover window and any error text - across
    every wave, not just the one currently open in the UI.

    Migration status reporting is the thing programme managers ask for daily, and the UI has no
    export. Group this by State and the daily update writes itself.

    Pain area addressed: #10 Cross-domain inventory.

.PARAMETER Server
    FQDN or IP address of the HCX Manager at the source site.

.PARAMETER Credential
    Credential used to authenticate to HCX Manager.

.PARAMETER State
    Limit to these migration states, for example MIGRATING, MIGRATED or FAILED.

.PARAMETER FailedOnly
    Return only migrations that have failed or been cancelled.

.PARAMETER OutputPath
    Path of the file to write. When omitted the records are only returned on the pipeline and
    nothing is written to disk.

.PARAMETER Format
    Output file format. CSV is the flat table, JSON carries the export envelope that the
    matching import script validates, HTML is a styled table for sharing.

.EXAMPLE
    PS> ./Export-HcxMigrationStatus.ps1 -Server hcx.example.local -Credential $cred | Group-Object State

    Summarises the whole migration programme by state.

.EXAMPLE
    PS> ./Export-HcxMigrationStatus.ps1 -Server hcx.example.local -Credential $cred -FailedOnly -OutputPath ./failed.csv

    Writes just the failures with their error text.

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
    [Parameter()] [string[]]$State,
    [Parameter()] [switch]$FailedOnly,
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
    Schema        = 'hcx.migration-status'
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

    $migrations = @(Get-HCXMigration -ErrorAction SilentlyContinue)
    Write-Verbose ("HCX reports {0} migration(s)." -f $migrations.Count)

    foreach ($migration in $migrations) {
        $state = [string]$migration.State

        if ($State -and $state -notin $State) { continue }
        if ($FailedOnly -and $state -notin @('FAILED', 'CANCELLED', 'MIGRATION_FAILED')) { continue }

        $records += [pscustomobject]@{
            VM                = [string]$migration.VM
            MigrationId       = $migration.MigrationId
            MigrationType     = [string]$migration.MigrationType
            SourceSite        = [string]$migration.SourceSite
            DestinationSite   = [string]$migration.DestinationSite
            State             = $state
            Progress          = $migration.Progress
            ScheduleStart     = $migration.ScheduleStartTime
            ScheduleEnd       = $migration.ScheduleEndTime
            DestinationFolder = [string]$migration.Folder
            DestinationStorage = [string]$migration.TargetDatastore
            DestinationCompute = [string]$migration.TargetComputeContainer
            RetainMac         = $migration.RetainMac
            ForcePowerOff     = $migration.ForcePowerOffVm
            Message           = ($migration.Message -replace '\s+', ' ')
        }
    }

    $records = @($records | Sort-Object State, VM)
    Write-Verbose ("Collected {0} migration record(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    if ($connection) { Disconnect-HCXServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
