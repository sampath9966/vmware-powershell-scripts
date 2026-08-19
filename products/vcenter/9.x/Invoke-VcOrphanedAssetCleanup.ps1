<#
.SYNOPSIS
    Removes the orphaned VMs and unreferenced VMDK files listed in a reviewed orphaned-asset export.

.DESCRIPTION
    Acts on a file produced by Export-VcOrphanedAsset.ps1. Orphaned VMs are unregistered from
    inventory, and zombie disks are deleted from the datastore - but only the findings you opt
    into with -Finding, and only after the script re-verifies each one still looks orphaned.

    This is the most destructive script in the repository, so it behaves accordingly: nothing
    runs without an explicit -Finding, every deletion is behind ShouldProcess with a High
    confirm impact, zombie disks are re-checked against live VM disk backings immediately before
    deletion, and -DiffOnly is the intended first run. Review the export by hand first.

    Pain area addressed: #5 Orphaned and zombie assets.

.PARAMETER Server
    FQDN or IP address of the vCenter Server to connect to.

.PARAMETER Credential
    Credential used to authenticate to vCenter Server.

.PARAMETER InputPath
    Path to the .json (preferred) or .csv file written by the matching Export-* script. The
    envelope is validated before anything is changed.

.PARAMETER Finding
    Which finding types to act on: OrphanedVM, ZombieDisk or StaleTemplate. Required - there is
    no default.

.PARAMETER MinimumAgeDays
    Only act on items whose last modification is at least this old. Defaults to 30.

.PARAMETER DiffOnly
    Show the planned changes and exit without applying any of them. Use this first, every time.

.EXAMPLE
    PS> ./Invoke-VcOrphanedAssetCleanup.ps1 -Server vcenter.example.local -Credential $cred -InputPath ./orphans.json -Finding ZombieDisk -DiffOnly

    Lists the zombie disks that would be deleted and the space that frees. Deletes nothing.

.EXAMPLE
    PS> ./Invoke-VcOrphanedAssetCleanup.ps1 -Server vcenter.example.local -Credential $cred -InputPath ./orphans.json -Finding OrphanedVM -Confirm

    Unregisters orphaned VMs one at a time, prompting for each.

.NOTES
    Author        : Sampath
    Product       : vCenter (VCF 9.x)
    Target        : VMware Cloud Foundation 9.x
    Modules       : VMware.VimAutomation.Core
    Behaviour     : Changes the target. Supports -WhatIf, -Confirm and -DiffOnly.
    Standalone    : Yes. This script does not dot-source or import any other file
                    in this repository and can be copied out on its own.
#>

#Requires -Version 5.1
#Requires -Modules VMware.VimAutomation.Core

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Server,
    [Parameter(Mandatory)] [System.Management.Automation.PSCredential]$Credential,
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$InputPath,
    [Parameter(Mandatory)] [string[]]$Finding,
    [Parameter()] [int]$MinimumAgeDays = 30,
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


$expectedSchema     = 'vcenter.orphaned-asset'
$expectedProduct    = 'vcenter'
$expectedVcfVersion = '9.x'

$connection = $null
try {
    $connection = Connect-VIServer -Server $Server -Credential $Credential -ErrorAction Stop
    Write-Verbose "Connected to vCenter Server $($connection.Name) (version $($connection.Version))"
    if (@($DefaultVIServers).Count -gt 1) {
        Write-Warning (("{0} vCenter connections are open in this session. PowerCLI cmdlets act on " +
            "every connected server unless they are scoped, which silently mixes inventories. " +
            "This script scopes its own calls to '{1}'.") -f @($DefaultVIServers).Count, $connection.Name)
    }
    # Scope every call in this script to the connection opened above. Without this,
    # PowerCLI cmdlets act on every connected server, which silently mixes inventories
    # when more than one is connected. The hashtable is cloned first because indexing
    # the inherited one would change the caller's session defaults too.
    $PSDefaultParameterValues = $PSDefaultParameterValues.Clone()
    $PSDefaultParameterValues['*:Server'] = $connection

    $desired = Read-ExportFile -Path $InputPath -ExpectedSchema $expectedSchema `
        -ExpectedProduct $expectedProduct -ExpectedVcfVersion $expectedVcfVersion

    Write-Verbose ("Input lists {0} finding(s). Acting only on: {1}." -f @($desired).Count, ($Finding -join ', '))

    $liveDisks = New-Object 'System.Collections.Generic.HashSet[string]'
    if ($Finding -contains 'ZombieDisk') {
        Write-Verbose 'Re-reading live VM disk backings so a stale input file cannot delete an in-use disk.'
        foreach ($disk in (Get-VM | Get-HardDisk -ErrorAction SilentlyContinue)) { [void]$liveDisks.Add($disk.Filename) }
        foreach ($disk in (Get-Template -ErrorAction SilentlyContinue | Get-HardDisk -ErrorAction SilentlyContinue)) { [void]$liveDisks.Add($disk.Filename) }
    }

    $plan = foreach ($record in @($desired)) {
        if ($record.Finding -notin $Finding) { continue }

        if ($MinimumAgeDays -gt 0 -and $record.LastModified) {
            $age = ((Get-Date) - [datetime]$record.LastModified).TotalDays
            if ($age -lt $MinimumAgeDays) {
                Write-Verbose "'$($record.Name)' is only $([int]$age) day(s) old. Skipping."
                continue
            }
        }

        if ($record.Finding -eq 'ZombieDisk' -and $liveDisks.Contains($record.Path)) {
            Write-Warning "'$($record.Path)' is referenced by a live VM now. It is NOT a zombie. Skipping."
            continue
        }

        [pscustomobject]@{
            Key             = $record.Path
            Action          = 'Remove'
            ChangedProperty = $record.Finding
            Finding         = $record.Finding
            Name            = $record.Name
            Path            = $record.Path
            SizeGB          = $record.SizeGB
            ObjectId        = $record.ObjectId
            Desired         = $record
            Current         = $null
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
    $reclaim = ($actionable | Measure-Object -Property SizeGB -Sum).Sum
    Write-Verbose ("Acting on {0} item(s), reclaiming roughly {1} GB." -f $actionable.Count, [math]::Round([double]$reclaim, 1))

    foreach ($item in $actionable) {
        $status = 'Skipped'
        $message = ''

        switch ($item.Finding) {
            'OrphanedVM' {
                if (-not $PSCmdlet.ShouldProcess("orphaned VM '$($item.Name)'", 'Remove from inventory')) { break }
                try {
                    $vm = Get-VM -Id $item.ObjectId -ErrorAction Stop
                    Remove-VM -VM $vm -DeletePermanently:$false -Confirm:$false -ErrorAction Stop
                    $status = 'Unregistered'
                }
                catch { $status = 'Failed'; $message = $_.Exception.Message }
            }
            'StaleTemplate' {
                if (-not $PSCmdlet.ShouldProcess("template '$($item.Name)'", 'Remove from inventory')) { break }
                try {
                    $template = Get-Template -Id $item.ObjectId -ErrorAction Stop
                    Remove-Template -Template $template -DeletePermanently:$false -Confirm:$false -ErrorAction Stop
                    $status = 'Unregistered'
                }
                catch { $status = 'Failed'; $message = $_.Exception.Message }
            }
            'ZombieDisk' {
                if (-not $PSCmdlet.ShouldProcess("disk file '$($item.Path)'", 'DELETE from datastore')) { break }
                try {
                    $storeName = ($item.Path -replace '^\[(.+?)\].*$', '$1')
                    $relative = ($item.Path -replace '^\[.+?\]\s*', '')
                    $store = Get-Datastore -Name $storeName -ErrorAction Stop
                    $driveName = 'vccl' + ([guid]::NewGuid().ToString('N').Substring(0, 6))
                    New-PSDrive -Name $driveName -PSProvider VimDatastore -Root '\' -Location $store -ErrorAction Stop | Out-Null
                    try {
                        Remove-Item -Path ($driveName + ':\' + ($relative -replace '/', '\')) -Force -ErrorAction Stop
                        $status = 'Deleted'
                    }
                    finally { Remove-PSDrive -Name $driveName -Force -ErrorAction SilentlyContinue }
                }
                catch { $status = 'Failed'; $message = $_.Exception.Message }
            }
        }

        [pscustomobject]@{
            Finding = $item.Finding
            Name    = $item.Name
            Path    = $item.Path
            SizeGB  = $item.SizeGB
            Status  = $status
            Message = $message
        }
    }
}
finally {
    if ($connection) { Disconnect-VIServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
