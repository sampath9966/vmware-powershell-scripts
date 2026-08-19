<#
.SYNOPSIS
    Creates HCX migrations in bulk from a CSV or JSON wave definition, validating every one before anything is created.

.DESCRIPTION
    Reads a wave file - one row per VM with its target compute, storage, folder, network mapping
    and migration type - validates each migration through HCX first, and creates the ones that
    pass. Migrations are created but not started unless -StartMigration is given.

    This is the script that replaces an afternoon of typing. The validation pass is the point:
    HCX reports what would fail before a single migration exists, so the wave is either correct
    or the file gets fixed, rather than half a wave being created and needing unpicking.

    Pain area addressed: #10 Cross-domain inventory; #16 Config portability between
    environments.

.PARAMETER Server
    FQDN or IP address of the HCX Manager at the source site.

.PARAMETER Credential
    Credential used to authenticate to HCX Manager.

.PARAMETER InputPath
    Path to the .json (preferred) or .csv file written by the matching Export-* script. The
    envelope is validated before anything is changed.

.PARAMETER MigrationType
    Migration type to use where the file does not specify one. Defaults to 'bulkVMotion'.

.PARAMETER StartMigration
    Start the migrations after creating them. Without this they are created in a pending state
    for review.

.PARAMETER SkipValidation
    Skip the per-migration validation pass. Not recommended - validation is the reason to use
    this script.

.PARAMETER DiffOnly
    Show the planned changes and exit without applying any of them. Use this first, every time.

.EXAMPLE
    PS> ./Import-HcxMigrationWave.ps1 -Server hcx.example.local -Credential $cred -InputPath ./wave1.csv -DiffOnly

    Validates every row in the wave and reports what would be created. Creates nothing.

.EXAMPLE
    PS> ./Import-HcxMigrationWave.ps1 -Server hcx.example.local -Credential $cred -InputPath ./wave1.csv -StartMigration -Confirm

    Creates and starts the wave, prompting per VM.

.NOTES
    Author        : Sampath
    Product       : VCF Operations HCX (VCF 9.x)
    Target        : VMware Cloud Foundation 9.x
    Modules       : VMware.VimAutomation.Hcx
    Behaviour     : Changes the target. Supports -WhatIf, -Confirm and -DiffOnly.
    Standalone    : Yes. This script does not dot-source or import any other file
                    in this repository and can be copied out on its own.
#>

#Requires -Version 5.1
#Requires -Modules VMware.VimAutomation.Hcx

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Server,
    [Parameter(Mandatory)] [System.Management.Automation.PSCredential]$Credential,
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$InputPath,
    [Parameter()] [string]$MigrationType = 'bulkVMotion',
    [Parameter()] [switch]$StartMigration,
    [Parameter()] [switch]$SkipValidation,
    [Parameter()] [switch]$DiffOnly
)

$ErrorActionPreference = 'Stop'

function Read-ExportFile {
    <#
        Loads a .json export envelope (or a flat .csv) produced by the matching
        Export-* script and refuses to continue if it describes something else.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedSchema,
        [Parameter(Mandatory)][string]$ExpectedProduct,
        [Parameter(Mandatory)][string]$ExpectedVcfVersion
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Input file not found: $Path"
    }

    switch ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        '.json' {
            $document = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
            $names = @($document.PSObject.Properties.Name)
            if ($names -notcontains 'schema') {
                Write-Verbose 'Input has no export envelope; treating the whole document as data.'
                return @($document)
            }
            if ($document.schema -ne $ExpectedSchema) {
                throw ("Schema mismatch. File declares '{0}' but this script expects '{1}'." -f $document.schema, $ExpectedSchema)
            }
            if ($document.product -and $document.product -ne $ExpectedProduct) {
                throw ("Product mismatch. File was exported from '{0}' but this script targets '{1}'." -f $document.product, $ExpectedProduct)
            }
            if ($document.vcfVersion -and $document.vcfVersion -ne $ExpectedVcfVersion) {
                Write-Warning ("File was exported from VCF {0} but this script targets VCF {1}. Review the diff carefully." -f $document.vcfVersion, $ExpectedVcfVersion)
            }
            return @($document.data)
        }
        '.csv' {
            Write-Verbose 'CSV input carries no envelope; schema and version cannot be validated.'
            return @(Import-Csv -LiteralPath $Path)
        }
        default {
            throw "Unsupported input format. Provide the .json or .csv file written by the matching Export-* script."
        }
    }
}


$expectedSchema     = 'hcx.migration-wave'
$expectedProduct    = 'vcf-operations-hcx'
$expectedVcfVersion = '9.x'

$connection = $null
try {
    $connection = Connect-HCXServer -Server $Server -Credential $Credential -ErrorAction Stop
    Write-Verbose "Connected to HCX Manager $($connection.Server)"

    $desired = Read-ExportFile -Path $InputPath -ExpectedSchema $expectedSchema `
        -ExpectedProduct $expectedProduct -ExpectedVcfVersion $expectedVcfVersion

    Write-Verbose ("Wave file lists {0} row(s)." -f @($desired).Count)

    $existing = @{}
    foreach ($migration in (Get-HCXMigration -ErrorAction SilentlyContinue)) {
        $existing[[string]$migration.VM] = $migration
    }

    $plan = foreach ($row in @($desired)) {
        if (-not $row.VM) { continue }

        if ($existing.ContainsKey($row.VM)) {
            [pscustomobject]@{
                Key = $row.VM; Action = 'Match'; ChangedProperty = ''
                VM = $row.VM; Validation = 'AlreadyExists'; ValidationMessage = ''
                Desired = $row; Current = $existing[$row.VM]
            }
            continue
        }

        $hcxVm = Get-HCXVM -Name $row.VM -ErrorAction SilentlyContinue
        if (-not $hcxVm) {
            Write-Warning "HCX cannot see a VM named '$($row.VM)'. Skipping."
            continue
        }

        $validation = 'NotChecked'
        $validationMessage = ''

        if (-not $SkipValidation) {
            try {
                $site = Get-HCXSite -Destination -Name $row.DestinationSite -ErrorAction Stop
                $container = Get-HCXContainer -Name $row.TargetComputeContainer -Site $site -ErrorAction Stop
                $datastore = Get-HCXDatastore -Name $row.TargetDatastore -Site $site -ErrorAction Stop

                $params = @{
                    VM                    = $hcxVm
                    SourceSite            = (Get-HCXSite -Source -ErrorAction Stop)
                    DestinationSite       = $site
                    TargetComputeContainer = $container
                    TargetDatastore       = $datastore
                    MigrationType         = if ($row.MigrationType) { $row.MigrationType } else { $MigrationType }
                }
                if ($row.Folder) {
                    $folder = Get-HCXContainer -Name $row.Folder -Site $site -Type Folder -ErrorAction SilentlyContinue
                    if ($folder) { $params['Folder'] = $folder }
                }

                $candidate = New-HCXMigration @params -ErrorAction Stop
                $result = Test-HCXMigration -Migration $candidate -ErrorAction Stop

                $validation = if ($result.State -eq 'VALIDATION_SUCCESS' -or -not $result.Error) { 'Passed' } else { 'Failed' }
                $validationMessage = ($result.Error -join '; ')
            }
            catch {
                $validation = 'Failed'
                $validationMessage = $_.Exception.Message
            }
        }

        [pscustomobject]@{
            Key               = $row.VM
            Action            = if ($validation -eq 'Failed') { 'Match' } else { 'Create' }
            ChangedProperty   = 'migration'
            VM                = $row.VM
            Validation        = $validation
            ValidationMessage = $validationMessage
            Desired           = $row
            Current           = $null
        }
    }

    foreach ($item in $plan) {
        if ($item.Validation -eq 'Failed') {
            Write-Warning ("Validation failed for '{0}': {1}" -f $item.VM, $item.ValidationMessage)
        }
    }

    $actionable = @($plan | Where-Object { $_.Action -ne 'Match' })
    Write-Verbose ("Plan: {0} change(s), {1} already in the desired state." -f $actionable.Count, (@($plan).Count - $actionable.Count))

    if ($DiffOnly) {
        Write-Warning ("-DiffOnly was specified, so NOTHING was changed. The plan below lists " +
            "{0} pending change(s). Re-run without -DiffOnly to apply it." -f $actionable.Count)
        return $plan
    }

    if ($actionable.Count -eq 0) {
        Write-Warning 'Everything already matches the desired state. Nothing to do.'
        return $plan
    }

    Write-Verbose ("Applying {0} change(s)." -f $actionable.Count)
    $sourceSite = Get-HCXSite -Source -ErrorAction Stop

    foreach ($item in $actionable) {
        $row = $item.Desired

        if (-not $PSCmdlet.ShouldProcess("VM '$($item.VM)' to $($row.DestinationSite)", 'Create HCX migration')) { continue }

        try {
            $site = Get-HCXSite -Destination -Name $row.DestinationSite -ErrorAction Stop

            $params = @{
                VM                     = (Get-HCXVM -Name $row.VM -ErrorAction Stop)
                SourceSite             = $sourceSite
                DestinationSite        = $site
                TargetComputeContainer = (Get-HCXContainer -Name $row.TargetComputeContainer -Site $site -ErrorAction Stop)
                TargetDatastore        = (Get-HCXDatastore -Name $row.TargetDatastore -Site $site -ErrorAction Stop)
                MigrationType          = if ($row.MigrationType) { $row.MigrationType } else { $MigrationType }
            }

            if ($row.Folder) {
                $folder = Get-HCXContainer -Name $row.Folder -Site $site -Type Folder -ErrorAction SilentlyContinue
                if ($folder) { $params['Folder'] = $folder }
            }
            if ($row.ScheduleStart) { $params['ScheduleStartTime'] = [datetime]$row.ScheduleStart }
            if ($row.ScheduleEnd) { $params['ScheduleEndTime'] = [datetime]$row.ScheduleEnd }
            if ($row.RetainMac) { $params['RetainMac'] = [System.Convert]::ToBoolean($row.RetainMac) }

            $migration = New-HCXMigration @params -ErrorAction Stop

            $started = $false
            if ($StartMigration) {
                Start-HCXMigration -Migration $migration -Confirm:$false -ErrorAction Stop | Out-Null
                $started = $true
            }

            [pscustomobject]@{
                VM          = $item.VM
                MigrationId = $migration.MigrationId
                Validation  = $item.Validation
                Started     = $started
                Status      = 'Created'
            }
        }
        catch {
            Write-Warning ("Could not create the migration for '{0}': {1}" -f $item.VM, $_.Exception.Message)
            [pscustomobject]@{ VM = $item.VM; MigrationId = ''; Validation = $item.Validation; Started = $false; Status = 'Failed' }
        }
    }
}
finally {
    if ($connection) { Disconnect-HCXServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
