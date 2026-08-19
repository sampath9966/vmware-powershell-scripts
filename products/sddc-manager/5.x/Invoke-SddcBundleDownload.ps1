<#
.SYNOPSIS
    Triggers download of the bundles listed in a bundle inventory export that are not yet staged.

.DESCRIPTION
    Reads a bundle inventory export, works out which of those bundles still need pulling, and
    schedules the downloads - optionally waiting for each one so the script can be the last step
    before an upgrade window rather than the first.

    Staging bundles by hand means clicking Download on each tile and then coming back later to
    see which ones silently failed. This submits them, records the task id for each, and reports
    the terminal status of every one.

    Calls PATCH /v1/bundles/{id} with a bundleDownloadSpec, then polls GET /v1/tasks/{id}.

    Pain area addressed: #12 Upgrade prechecks and bundle state.

.PARAMETER Server
    FQDN or IP address of the SDDC Manager appliance.

.PARAMETER Credential
    Credential used to authenticate to SDDC Manager (for example administrator@vsphere.local).

.PARAMETER InputPath
    Path to the .json (preferred) or .csv file written by the matching Export-* script. The
    envelope is validated before anything is changed.

.PARAMETER BundleType
    Limit the download to these bundle types, for example PATCH or DRIVER.

.PARAMETER Wait
    Wait for each download to reach a terminal state instead of scheduling and returning
    immediately.

.PARAMETER TimeoutMinutes
    How long to wait per bundle when -Wait is used. Defaults to 120, because bundles are large.

.PARAMETER IgnoreInvalidCertificate
    Accept an untrusted or self-signed certificate on the SDDC Manager endpoint. Use only in lab
    environments.

.PARAMETER DiffOnly
    Show the planned changes and exit without applying any of them. Use this first, every time.

.EXAMPLE
    PS> ./Invoke-SddcBundleDownload.ps1 -Server sddc.example.local -Credential $cred -InputPath ./bundles.json -DiffOnly

    Lists which bundles would be pulled and how much disk that needs. Changes nothing.

.EXAMPLE
    PS> ./Invoke-SddcBundleDownload.ps1 -Server sddc.example.local -Credential $cred -InputPath ./bundles.json -Wait -Confirm

    Downloads each outstanding bundle in turn and reports the final status of each.

.NOTES
    Author        : Sampath
    Product       : SDDC Manager (VCF 5.x)
    Target        : VMware Cloud Foundation 5.x
    Modules       : VMware.Sdk.Vcf.SddcManager
    Behaviour     : Changes the target. Supports -WhatIf, -Confirm and -DiffOnly.
    Standalone    : Yes. This script does not dot-source or import any other file
                    in this repository and can be copied out on its own.
#>

#Requires -Version 5.1
#Requires -Modules VMware.Sdk.Vcf.SddcManager

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Server,
    [Parameter(Mandatory)] [System.Management.Automation.PSCredential]$Credential,
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$InputPath,
    [Parameter()] [string[]]$BundleType,
    [Parameter()] [switch]$Wait,
    [Parameter()] [int]$TimeoutMinutes = 120,
    [Parameter()] [switch]$IgnoreInvalidCertificate,
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


$expectedSchema     = 'vcf.sddc.bundle-inventory'
$expectedProduct    = 'sddc-manager'
$expectedVcfVersion = '5.x'

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

    $desired = Read-ExportFile -Path $InputPath -ExpectedSchema $expectedSchema `
        -ExpectedProduct $expectedProduct -ExpectedVcfVersion $expectedVcfVersion

    Write-Verbose ("Input file lists {0} bundle record(s)." -f @($desired).Count)

    $plan = foreach ($record in @($desired)) {
        if ($BundleType -and $record.Type -notin $BundleType) { continue }

        $action = if ($record.DownloadStatus -eq 'SUCCESSFUL') { 'Match' } else { 'Update' }

        [pscustomobject]@{
            Key             = $record.BundleId
            Action          = $action
            ChangedProperty = if ($action -eq 'Update') { 'downloadStatus' } else { '' }
            Type            = $record.Type
            Version         = $record.Version
            SizeMB          = $record.SizeMB
            DownloadStatus  = $record.DownloadStatus
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
    $totalMb = ($actionable | Measure-Object -Property SizeMB -Sum).Sum
    Write-Verbose ("About to stage {0} bundle(s), roughly {1} MB." -f $actionable.Count, [math]::Round([double]$totalMb, 0))

    foreach ($item in $actionable) {
        $target = "bundle {0} ({1} {2}, {3} MB)" -f $item.Key, $item.Type, $item.Version, $item.SizeMB

        if (-not $PSCmdlet.ShouldProcess($target, 'Download bundle')) {
            continue
        }

        $spec = Initialize-VcfBundleUpdateSpec -BundleDownloadSpec (
            Initialize-VcfBundleDownloadSpec -DownloadNow $true
        )
        $task = Invoke-VcfUpdateBundle -Id $item.Key -BundleUpdateSpec $spec

        if ($Wait) {
            $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
            while ((Get-Date) -lt $deadline) {
                $task = Invoke-VcfGetTask -Id $task.Id
                if ($task.Status -in @('SUCCESSFUL', 'FAILED', 'CANCELLED')) { break }
                Start-Sleep -Seconds 30
            }
        }

        [pscustomobject]@{
            BundleId = $item.Key
            Type     = $item.Type
            Version  = $item.Version
            SizeMB   = $item.SizeMB
            TaskId   = $task.Id
            Status   = $task.Status
        }
    }
}
finally {
    if ($connection) { Disconnect-VcfSddcManagerServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
