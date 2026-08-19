<#
.SYNOPSIS
    Applies a captured password policy baseline, changing only the resource types that differ.

.DESCRIPTION
    Reads a password policy export, compares it against what the target currently enforces, and
    updates only the resource types whose settings differ. Everything already matching is
    reported as Match and left untouched.

    Tightening a password policy takes effect at the next password change, so this is safe to
    run outside a window - but it will change expiry behaviour for every account of that type,
    which is why -DiffOnly comes first and every update is behind ShouldProcess.

    Calls GET then PUT /v1/system/security/password-policies.

    Pain area addressed: #2 Credential rotation and expiry; #16 Config portability between
    environments.

.PARAMETER Server
    FQDN or IP address of the SDDC Manager appliance.

.PARAMETER Credential
    Credential used to authenticate to SDDC Manager (for example administrator@vsphere.local).

.PARAMETER InputPath
    Path to the .json (preferred) or .csv file written by the matching Export-* script. The
    envelope is validated before anything is changed.

.PARAMETER ResourceType
    Limit the change to these resource types.

.PARAMETER IgnoreInvalidCertificate
    Accept an untrusted or self-signed certificate on the SDDC Manager endpoint. Use only in lab
    environments.

.PARAMETER DiffOnly
    Show the planned changes and exit without applying any of them. Use this first, every time.

.EXAMPLE
    PS> ./Import-SddcPasswordPolicy.ps1 -Server sddc2.example.local -Credential $cred -InputPath ./policy.json -DiffOnly

    Shows exactly which policy fields differ between the baseline and this instance.

.EXAMPLE
    PS> ./Import-SddcPasswordPolicy.ps1 -Server sddc2.example.local -Credential $cred -InputPath ./policy.json -Confirm

    Brings the instance in line with the baseline, prompting per resource type.

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
    [Parameter()] [string[]]$ResourceType,
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

function Compare-DesiredState {
    <#
        Joins the desired records from the input file against what the target
        currently has, and labels each one Create, Update or Match so the plan can
        be reviewed before a single change is committed.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowEmptyCollection()][object[]]$Current,
        [Parameter()][AllowEmptyCollection()][object[]]$Desired,
        [Parameter(Mandatory)][string]$KeyProperty,
        [Parameter()][string[]]$CompareProperty
    )

    $index = @{}
    foreach ($item in @($Current)) {
        $key = [string]$item.$KeyProperty
        if ($key) { $index[$key] = $item }
    }

    foreach ($item in @($Desired)) {
        $key = [string]$item.$KeyProperty
        if (-not $key) {
            Write-Warning "Skipping a desired record with no '$KeyProperty' value."
            continue
        }

        $existing = $index[$key]
        $changed = @()

        if ($null -eq $existing) {
            $action = 'Create'
        }
        else {
            $properties = if ($CompareProperty) { $CompareProperty } else { @($item.PSObject.Properties.Name) }
            foreach ($property in $properties) {
                if ($property -eq $KeyProperty) { continue }
                $left  = [string]$existing.$property
                $right = [string]$item.$property
                if ($left -ne $right) { $changed += $property }
            }
            $action = if ($changed.Count -gt 0) { 'Update' } else { 'Match' }
        }

        [pscustomobject]@{
            Key             = $key
            Action          = $action
            ChangedProperty = ($changed -join ', ')
            Desired         = $item
            Current         = $existing
        }
    }
}

$expectedSchema     = 'vcf.sddc.password-policy'
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

    if ($ResourceType) {
        $desired = @($desired | Where-Object { $_.ResourceType -in $ResourceType })
    }

    $current = foreach ($policy in @((Invoke-VcfGetPasswordPolicies).Elements)) {
        [pscustomobject]@{
            ResourceType       = $policy.ResourceType
            MinLength          = $policy.PasswordComplexity.MinLength
            MaxLength          = $policy.PasswordComplexity.MaxLength
            MinLowercase       = $policy.PasswordComplexity.MinLowercaseCharacters
            MinUppercase       = $policy.PasswordComplexity.MinUppercaseCharacters
            MinNumeric         = $policy.PasswordComplexity.MinNumericCharacters
            MinSpecial         = $policy.PasswordComplexity.MinSpecialCharacters
            History            = $policy.PasswordComplexity.History
            MaxAgeDays         = $policy.PasswordExpiration.MaxDays
            MinAgeDays         = $policy.PasswordExpiration.MinDays
            WarningDays        = $policy.PasswordExpiration.WarningDays
            LockoutFailures    = $policy.AccountLockout.MaxFailedAttempts
            LockoutIntervalSec = $policy.AccountLockout.UnlockIntervalInSecond
        }
    }

    Write-Verbose ("Comparing {0} desired policy row(s) against {1} current row(s)." -f @($desired).Count, @($current).Count)

    $plan = Compare-DesiredState -Current @($current) -Desired @($desired) -KeyProperty 'ResourceType'

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
    foreach ($item in $actionable) {
        $record = $item.Desired
        $target = "password policy for {0}" -f $item.Key

        if (-not $PSCmdlet.ShouldProcess($target, "Update ($($item.ChangedProperty))")) {
            continue
        }

        $complexity = Initialize-VcfPasswordComplexity `
            -MinLength ([int]$record.MinLength) `
            -MaxLength ([int]$record.MaxLength) `
            -MinLowercaseCharacters ([int]$record.MinLowercase) `
            -MinUppercaseCharacters ([int]$record.MinUppercase) `
            -MinNumericCharacters ([int]$record.MinNumeric) `
            -MinSpecialCharacters ([int]$record.MinSpecial) `
            -History ([int]$record.History)

        $expiration = Initialize-VcfPasswordExpiration `
            -MaxDays ([int]$record.MaxAgeDays) `
            -MinDays ([int]$record.MinAgeDays) `
            -WarningDays ([int]$record.WarningDays)

        $lockout = Initialize-VcfAccountLockout `
            -MaxFailedAttempts ([int]$record.LockoutFailures) `
            -UnlockIntervalInSecond ([int]$record.LockoutIntervalSec)

        $spec = Initialize-VcfPasswordPolicyUpdateSpec `
            -ResourceType $item.Key `
            -PasswordComplexity $complexity `
            -PasswordExpiration $expiration `
            -AccountLockout $lockout

        Invoke-VcfUpdatePasswordPolicy -PasswordPolicyUpdateSpec $spec | Out-Null

        [pscustomobject]@{
            ResourceType = $item.Key
            Action       = $item.Action
            Changed      = $item.ChangedProperty
            Status       = 'Applied'
        }
    }
}
finally {
    if ($connection) { Disconnect-VcfSddcManagerServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
