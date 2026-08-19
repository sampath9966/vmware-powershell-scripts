<#
.SYNOPSIS
    Validates a deployment spec and, only if validation passes, starts the bring-up from it.

.DESCRIPTION
    Reads a spec file, runs the full validation against it, and refuses to go any further unless
    validation comes back clean. Only then does it submit the bring-up, and only with explicit
    confirmation.

    This is the most consequential script in the repository - it builds an environment. The
    validation gate is not optional and cannot be skipped: a spec that fails validation is
    reported and the run stops. Use -DiffOnly to validate and stop deliberately.

    Pain area addressed: #12 Upgrade prechecks and bundle state.

.PARAMETER Server
    FQDN or IP address of the Cloud Builder appliance.

.PARAMETER Credential
    Credential used to authenticate to the Cloud Builder appliance (default user 'admin').

.PARAMETER SpecPath
    Path to the deployment spec JSON file to deploy from.

.PARAMETER TimeoutMinutes
    How long to wait for validation to finish. Defaults to 45.

.PARAMETER Wait
    Poll the bring-up to completion after starting it instead of returning immediately.

.PARAMETER BringUpTimeoutHours
    How long to poll the bring-up for when -Wait is used. Defaults to 6.

.PARAMETER IgnoreInvalidCertificate
    Accept an untrusted or self-signed certificate on the Cloud Builder endpoint. Use only in
    lab environments.

.PARAMETER DiffOnly
    Show the planned changes and exit without applying any of them. Use this first, every time.

.EXAMPLE
    PS> ./Import-InstallerSddcDeployment.ps1 -Server cb.example.local -Credential $cred -SpecPath ./sddc-spec.json -DiffOnly

    Runs validation and stops, whatever the result. Deploys nothing.

.EXAMPLE
    PS> ./Import-InstallerSddcDeployment.ps1 -Server cb.example.local -Credential $cred -SpecPath ./sddc-spec.json -Wait -Confirm

    Validates, asks for confirmation, then starts the bring-up and follows it to completion.

.NOTES
    Author        : Sampath
    Product       : Cloud Builder (VCF 5.x)
    Target        : VMware Cloud Foundation 5.x
    Modules       : VMware.Sdk.Vcf.CloudBuilder
    Behaviour     : Changes the target. Supports -WhatIf, -Confirm and -DiffOnly.
    Standalone    : Yes. This script does not dot-source or import any other file
                    in this repository and can be copied out on its own.
#>

#Requires -Version 5.1
#Requires -Modules VMware.Sdk.Vcf.CloudBuilder

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Server,
    [Parameter(Mandatory)] [System.Management.Automation.PSCredential]$Credential,
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$SpecPath,
    [Parameter()] [int]$TimeoutMinutes = 45,
    [Parameter()] [switch]$Wait,
    [Parameter()] [int]$BringUpTimeoutHours = 6,
    [Parameter()] [switch]$IgnoreInvalidCertificate,
    [Parameter()] [switch]$DiffOnly
)

$ErrorActionPreference = 'Stop'


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

    if (-not (Test-Path -LiteralPath $SpecPath)) { throw "Spec file not found: $SpecPath" }

    $spec = Get-Content -LiteralPath $SpecPath -Raw | ConvertFrom-Json
    Write-Verbose "Validating '$SpecPath' before considering any deployment."

    $validation = Invoke-VcfValidateSddcSpec -SddcSpec $spec

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $deadline) {
        $validation = Invoke-VcfGetSddcValidation -Id $validation.Id
        if ($validation.ExecutionStatus -in @('COMPLETED', 'FAILED', 'CANCELLED')) { break }
        Start-Sleep -Seconds 15
    }

    $failures = @($validation.ValidationChecks | Where-Object { $_.ResultStatus -notin @('SUCCEEDED', 'PASSED') })
    $passed = ($validation.ResultStatus -in @('SUCCEEDED', 'PASSED')) -and ($failures.Count -eq 0)

    Write-Verbose ("Validation result '{0}' with {1} failing check(s)." -f $validation.ResultStatus, $failures.Count)

    foreach ($failure in $failures) {
        Write-Warning ("Validation failure: {0} - {1}" -f $failure.Description, ($failure.ErrorResponse.Message -replace '\s+', ' '))
    }

    $plan = @(
        [pscustomobject]@{
            Key             = (Split-Path $SpecPath -Leaf)
            Action          = if ($passed) { 'Create' } else { 'Match' }
            ChangedProperty = 'deployment'
            ValidationId    = $validation.Id
            ValidationResult = $validation.ResultStatus
            FailingChecks   = $failures.Count
            SddcName        = $spec.SddcId
            HostCount       = @($spec.HostSpecs).Count
            Desired         = $spec
            Current         = $null
        }
    )

    if (-not $passed) {
        Write-Warning 'Validation did not pass. This script will not deploy from a spec that fails validation.'
    }

    $actionable = @($plan | Where-Object { $_.Action -ne 'Match' })
    Write-Verbose ("Plan: {0} change(s), {1} already in the desired state." -f $actionable.Count, (@($plan).Count - $actionable.Count))

    if ($DiffOnly) {
        Write-Verbose '-DiffOnly was specified. Nothing was changed.'
        return $plan
    }

    if ($actionable.Count -eq 0) {
        Write-Verbose 'Everything already matches the desired state. Nothing to do.'
        return $plan
    }
    foreach ($item in $actionable) {
        $target = "a new SDDC named '{0}' across {1} host(s) from spec '{2}'" -f $item.SddcName, $item.HostCount, $item.Key

        if (-not $PSCmdlet.ShouldProcess($target, 'START BRING-UP')) { continue }

        try {
            $deployment = Invoke-VcfCreateSddc -SddcSpec $item.Desired
            Write-Verbose ("Bring-up {0} submitted." -f $deployment.Id)

            if ($Wait) {
                $deadline = (Get-Date).AddHours($BringUpTimeoutHours)
                while ((Get-Date) -lt $deadline) {
                    $deployment = Invoke-VcfGetSddc -Id $deployment.Id
                    if ($deployment.Status -in @('COMPLETED_WITH_SUCCESS', 'COMPLETED_WITH_FAILURE', 'FAILED')) { break }
                    Write-Verbose ("  status {0}, current task '{1}'" -f $deployment.Status, $deployment.CurrentTask)
                    Start-Sleep -Seconds 60
                }
            }

            [pscustomobject]@{
                SpecFile     = $item.Key
                SddcId       = $deployment.Id
                SddcName     = $item.SddcName
                ValidationId = $item.ValidationId
                Status       = $deployment.Status
            }
        }
        catch {
            Write-Warning ("Could not start the bring-up: {0}" -f $_.Exception.Message)
            [pscustomobject]@{ SpecFile = $item.Key; SddcId = ''; SddcName = $item.SddcName; ValidationId = $item.ValidationId; Status = 'Failed' }
        }
    }
}
finally {
    if ($connection) { Disconnect-VcfCloudBuilderServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
