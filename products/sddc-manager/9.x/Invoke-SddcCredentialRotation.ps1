<#
.SYNOPSIS
    Rotates SDDC Manager managed passwords for the accounts listed in a credential inventory export.

.DESCRIPTION
    Reads a credential inventory export, filters it down to the accounts you actually want to
    rotate, and submits them to SDDC Manager in batches so a single failure does not leave a
    half-rotated estate behind.

    Rotating everything at once is what turns a routine maintenance task into an outage: a
    failed rotation mid-run can leave SDDC Manager and the component disagreeing about the
    password. -BatchSize keeps each submission small, the task is polled to a terminal state
    before the next batch starts, and a failed batch stops the run unless -ContinueOnError is
    given.

    Calls POST /v1/credentials with an operationType of ROTATE, then polls GET /v1/tasks/{id}.

    Pain area addressed: #2 Credential rotation and expiry.

.PARAMETER Server
    FQDN or IP address of the SDDC Manager appliance.

.PARAMETER Credential
    Credential used to authenticate to SDDC Manager (for example administrator@vsphere.local).

.PARAMETER InputPath
    Path to the .json (preferred) or .csv file written by the matching Export-* script. The
    envelope is validated before anything is changed.

.PARAMETER OlderThanDays
    Only rotate accounts whose password is at least this many days old. Defaults to 0, meaning
    every account in the file.

.PARAMETER ResourceType
    Limit rotation to these resource types, for example ESXI or NSXT_MANAGER.

.PARAMETER BatchSize
    How many accounts to submit in a single rotation task. Defaults to 5. Keep this small.

.PARAMETER TimeoutMinutes
    How long to wait for each batch task to finish before treating it as stalled. Defaults to
    45.

.PARAMETER ContinueOnError
    Carry on with the remaining batches after a batch fails. By default the run stops at the
    first failure.

.PARAMETER IgnoreInvalidCertificate
    Accept an untrusted or self-signed certificate on the SDDC Manager endpoint. Use only in lab
    environments.

.PARAMETER DiffOnly
    Show the planned changes and exit without applying any of them. Use this first, every time.

.EXAMPLE
    PS> ./Invoke-SddcCredentialRotation.ps1 -Server sddc.example.local -Credential $cred -InputPath ./creds.json -DiffOnly

    Prints the rotation plan - which accounts, in which batches - and changes nothing.

.EXAMPLE
    PS> ./Invoke-SddcCredentialRotation.ps1 -Server sddc.example.local -Credential $cred -InputPath ./creds.json -ResourceType ESXI -BatchSize 3 -Confirm

    Rotates only ESX host accounts, three at a time, prompting before each batch.

.NOTES
    Author        : Sampath
    Product       : SDDC Manager (VCF 9.x)
    Target        : VMware Cloud Foundation 9.x
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
    [Parameter()] [int]$OlderThanDays = 0,
    [Parameter()] [string[]]$ResourceType,
    [Parameter()] [int]$BatchSize = 5,
    [Parameter()] [int]$TimeoutMinutes = 45,
    [Parameter()] [switch]$ContinueOnError,
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


$expectedSchema     = 'vcf.sddc.credential-inventory'
$expectedProduct    = 'sddc-manager'
$expectedVcfVersion = '9.x'

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

    Write-Verbose ("Input file lists {0} credential record(s)." -f @($desired).Count)

    $selected = foreach ($record in @($desired)) {
        if ($ResourceType -and $record.ResourceType -notin $ResourceType) { continue }

        $age = $null
        if ($null -ne $record.PasswordAgeDays -and $record.PasswordAgeDays -ne '') {
            $age = [int]$record.PasswordAgeDays
        }
        if ($OlderThanDays -gt 0 -and ($null -eq $age -or $age -lt $OlderThanDays)) { continue }

        $record
    }

    $selected = @($selected)
    $batchNumber = 0
    $plan = for ($i = 0; $i -lt $selected.Count; $i += $BatchSize) {
        $batchNumber++
        foreach ($record in $selected[$i..([math]::Min($i + $BatchSize - 1, $selected.Count - 1))]) {
            [pscustomobject]@{
                Key             = '{0}\{1}' -f $record.ResourceFqdn, $record.Username
                Action          = 'Update'
                ChangedProperty = 'password'
                Batch           = $batchNumber
                ResourceFqdn    = $record.ResourceFqdn
                ResourceType    = $record.ResourceType
                Username        = $record.Username
                PasswordAgeDays = $record.PasswordAgeDays
                Desired         = $record
                Current         = $null
            }
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
    foreach ($batch in ($actionable | Group-Object -Property Batch)) {
        $names = @($batch.Group.Key)
        $target = "batch {0}: {1}" -f $batch.Name, ($names -join ', ')

        if (-not $PSCmdlet.ShouldProcess($target, 'Rotate password')) {
            continue
        }

        $elements = foreach ($item in $batch.Group) {
            $baseCredential = Initialize-VcfBaseCredential -Username $item.Username
            Initialize-VcfResourceCredentials -ResourceType $item.ResourceType `
                -ResourceName $item.ResourceFqdn -Credentials $baseCredential
        }

        $spec = Initialize-VcfCredentialsUpdateSpec -OperationType 'ROTATE' -Elements @($elements)
        $task = Invoke-VcfUpdateOrRotatePasswords -CredentialsUpdateSpec $spec

        $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
        while ((Get-Date) -lt $deadline) {
            $task = Invoke-VcfGetTask -Id $task.Id
            if ($task.Status -in @('SUCCESSFUL', 'FAILED', 'CANCELLED')) { break }
            Start-Sleep -Seconds 20
        }

        [pscustomobject]@{
            Batch     = $batch.Name
            Accounts  = $names -join ', '
            TaskId    = $task.Id
            Status    = $task.Status
            Message   = $task.Errors.Message -join '; '
        }

        if ($task.Status -ne 'SUCCESSFUL' -and -not $ContinueOnError) {
            throw ("Batch {0} finished with status '{1}'. Stopping. Re-run with -ContinueOnError to push through failures." -f $batch.Name, $task.Status)
        }
    }
}
finally {
    if ($connection) { Disconnect-VcfSddcManagerServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
