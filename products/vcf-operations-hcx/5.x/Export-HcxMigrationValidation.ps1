<#
.SYNOPSIS
    Re-validates every migration that has not yet started and reports what would block it.

.DESCRIPTION
    Finds migrations sitting in a pending or created state, runs the HCX validation against each
    and returns the result with the specific error text where one fails.

    Validations pass at creation time and quietly stop being true - a datastore fills, a network
    gets renamed, a VM gets a new disk. Running this the morning of a wave is what stops the
    wave failing at three in the morning.

    Pain area addressed: #10 Cross-domain inventory.

.PARAMETER Server
    FQDN or IP address of the HCX Manager at the source site.

.PARAMETER Credential
    Credential used to authenticate to HCX Manager.

.PARAMETER VM
    Limit validation to migrations for these VMs.

.PARAMETER FailuresOnly
    Return only migrations whose validation did not pass.

.PARAMETER OutputPath
    Path of the file to write. When omitted the records are only returned on the pipeline and
    nothing is written to disk.

.PARAMETER Format
    Output file format. CSV is the flat table, JSON carries the export envelope that the
    matching import script validates, HTML is a styled table for sharing.

.EXAMPLE
    PS> ./Export-HcxMigrationValidation.ps1 -Server hcx.example.local -Credential $cred -FailuresOnly

    Re-validates the pending wave and lists only what would fail.

.NOTES
    Author        : Sampath
    Product       : HCX (VCF 5.x)
    Target        : VMware Cloud Foundation 5.x
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
    [Parameter()] [string[]]$VM,
    [Parameter()] [switch]$FailuresOnly,
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
    Schema        = 'hcx.migration-validation'
    SchemaVersion = '1.0'
    Product       = 'vcf-operations-hcx'
    VcfVersion    = '5.x'
    Server        = $Server
}

$connection = $null
try {
    $connection = Connect-HCXServer -Server $Server -Credential $Credential -ErrorAction Stop
    Write-Verbose "Connected to HCX Manager $($connection.Server)"

    $records = @()

    $pending = @(Get-HCXMigration -ErrorAction SilentlyContinue |
        Where-Object { [string]$_.State -in @('CREATED', 'PENDING', 'VALIDATION_FAILED', 'READY') })
    Write-Verbose ("Found {0} migration(s) that have not started yet." -f $pending.Count)

    foreach ($migration in $pending) {
        $vmName = [string]$migration.VM
        if ($VM -and $vmName -notin $VM) { continue }

        $result = $null
        $status = 'Passed'
        $message = ''

        try {
            $result = Test-HCXMigration -Migration $migration -ErrorAction Stop
            if ($result.Error) {
                $status = 'Failed'
                $message = ($result.Error -join '; ')
            }
        }
        catch {
            $status = 'Failed'
            $message = $_.Exception.Message
        }

        if ($FailuresOnly -and $status -eq 'Passed') { continue }

        $records += [pscustomobject]@{
            VM               = $vmName
            MigrationId      = $migration.MigrationId
            MigrationType    = [string]$migration.MigrationType
            DestinationSite  = [string]$migration.DestinationSite
            CurrentState     = [string]$migration.State
            ValidationStatus = $status
            Message          = ($message -replace '\s+', ' ')
            CheckedAt        = (Get-Date).ToString('u')
        }
    }

    $records = @($records | Sort-Object ValidationStatus, VM)
    Write-Verbose ("Validated {0} migration(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    if ($connection) { Disconnect-HCXServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
