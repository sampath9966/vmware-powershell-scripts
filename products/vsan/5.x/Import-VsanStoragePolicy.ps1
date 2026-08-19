<#
.SYNOPSIS
    Creates the storage policies from an export that do not exist in the target vCenter.

.DESCRIPTION
    Compares the policies in the file against what the target has and creates the missing ones,
    reconstructing their rule sets from the exported capability and value pairs. Policies that
    already exist are reported as Match and left untouched.

    A capability that does not exist in the target - because the provider is not registered
    there - is reported and that policy is skipped rather than created half-formed.

    Pain area addressed: #16 Config portability between environments.

.PARAMETER Server
    FQDN or IP address of the vCenter Server to connect to.

.PARAMETER Credential
    Credential used to authenticate to vCenter Server.

.PARAMETER InputPath
    Path to the .json (preferred) or .csv file written by the matching Export-* script. The
    envelope is validated before anything is changed.

.PARAMETER PolicyName
    Limit the import to these policy names.

.PARAMETER DiffOnly
    Show the planned changes and exit without applying any of them. Use this first, every time.

.EXAMPLE
    PS> ./Import-VsanStoragePolicy.ps1 -Server vcenter2.example.local -Credential $cred -InputPath ./policies.json -DiffOnly

    Shows which policies are missing from the target vCenter.

.NOTES
    Author        : Sampath
    Product       : vSAN (VCF 5.x)
    Target        : VMware Cloud Foundation 5.x
    Modules       : VMware.VimAutomation.Core, VMware.VimAutomation.Storage
    Behaviour     : Changes the target. Supports -WhatIf, -Confirm and -DiffOnly.
    Standalone    : Yes. This script does not dot-source or import any other file
                    in this repository and can be copied out on its own.
#>

#Requires -Version 5.1
#Requires -Modules VMware.VimAutomation.Core
#Requires -Modules VMware.VimAutomation.Storage

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Server,
    [Parameter(Mandatory)] [System.Management.Automation.PSCredential]$Credential,
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$InputPath,
    [Parameter()] [string[]]$PolicyName,
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

$expectedSchema     = 'vsan.storage-policy'
$expectedProduct    = 'vsan'
$expectedVcfVersion = '5.x'

$connection = $null
try {
    $connection = Connect-VIServer -Server $Server -Credential $Credential -ErrorAction Stop
    Write-Verbose "Connected to vCenter Server $($connection.Name) (version $($connection.Version))"

    $desired = Read-ExportFile -Path $InputPath -ExpectedSchema $expectedSchema `
        -ExpectedProduct $expectedProduct -ExpectedVcfVersion $expectedVcfVersion

    if ($PolicyName) { $desired = @($desired | Where-Object { $_.Name -in $PolicyName }) }

    $current = foreach ($policy in (Get-SpbmStoragePolicy -ErrorAction SilentlyContinue)) {
        [pscustomobject]@{ Name = $policy.Name; Description = $policy.Description }
    }

    Write-Verbose ("Input lists {0} policy/policies; the target has {1}." -f @($desired).Count, @($current).Count)

    $plan = Compare-DesiredState -Current @($current) -Desired @($desired) `
        -KeyProperty 'Name' -CompareProperty @('Description')

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
    $capabilities = @{}
    foreach ($capability in (Get-SpbmCapability -ErrorAction SilentlyContinue)) { $capabilities[$capability.Name] = $capability }

    foreach ($item in ($actionable | Where-Object { $_.Action -eq 'Create' })) {
        $row = $item.Desired

        $ruleSets = @()
        $missing = @()
        foreach ($ruleSetText in @($row.RuleSets -split '\s*\|\s*' | Where-Object { $_ })) {
            $rules = @()
            foreach ($pair in @($ruleSetText -split '\s*,\s*' | Where-Object { $_ })) {
                $name, $value = $pair -split '=', 2
                if (-not $capabilities.ContainsKey($name)) { $missing += $name; continue }
                $rules += New-SpbmRule -Capability $capabilities[$name] -Value $value
            }
            if ($rules) { $ruleSets += New-SpbmRuleSet -AllOfRules $rules }
        }

        if ($missing) {
            Write-Warning ("Policy '{0}' needs capabilities not present in this vCenter: {1}. Skipping." -f $item.Key, (($missing | Sort-Object -Unique) -join ', '))
            [pscustomobject]@{ Policy = $item.Key; Status = 'SkippedMissingCapability' }
            continue
        }

        if (-not $ruleSets) {
            Write-Warning "Policy '$($item.Key)' has no reconstructable rules. Skipping."
            [pscustomobject]@{ Policy = $item.Key; Status = 'SkippedNoRules' }
            continue
        }

        if (-not $PSCmdlet.ShouldProcess("storage policy '$($item.Key)'", 'Create')) { continue }

        try {
            New-SpbmStoragePolicy -Name $item.Key -Description $row.Description `
                -AnyOfRuleSets $ruleSets -Confirm:$false -ErrorAction Stop | Out-Null
            [pscustomobject]@{ Policy = $item.Key; Status = 'Created' }
        }
        catch {
            Write-Warning ("Could not create policy '{0}': {1}" -f $item.Key, $_.Exception.Message)
            [pscustomobject]@{ Policy = $item.Key; Status = 'Failed' }
        }
    }
}
finally {
    if ($connection) { Disconnect-VIServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
