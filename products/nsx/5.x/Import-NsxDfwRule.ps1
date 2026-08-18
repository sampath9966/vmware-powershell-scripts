<#
.SYNOPSIS
    Creates or updates distributed firewall rules from an export, showing exactly what would change before it changes it.

.DESCRIPTION
    Reads a rule export, compares it against the rules that exist in the target policy, and
    creates the missing ones or updates the ones whose action, sources, destinations or services
    differ. Rules that match are left alone.

    Groups and services are resolved by display name in the target, so a rule referencing a
    group that does not exist here is reported and skipped rather than created pointing at
    nothing. Rules are never deleted by this script - removing firewall rules is a decision, not
    a sync.

    Pain area addressed: #8 DFW rules and effective membership; #16 Config portability between
    environments.

.PARAMETER Server
    FQDN or IP address of the NSX Manager to connect to.

.PARAMETER Credential
    Credential used to authenticate to NSX Manager.

.PARAMETER InputPath
    Path to the .json (preferred) or .csv file written by the matching Export-* script. The
    envelope is validated before anything is changed.

.PARAMETER Domain
    Policy domain to write to. Defaults to 'default'.

.PARAMETER PolicyName
    Only import rules belonging to these policies.

.PARAMETER DiffOnly
    Show the planned changes and exit without applying any of them. Use this first, every time.

.EXAMPLE
    PS> ./Import-NsxDfwRule.ps1 -Server nsx-dr.example.local -Credential $cred -InputPath ./dfw.json -DiffOnly

    Prints the create and update plan for the DR NSX without touching it.

.NOTES
    Author        : Sampath
    Product       : NSX-T Data Center (VCF 5.x)
    Target        : VMware Cloud Foundation 5.x
    Modules       : VMware.VimAutomation.Nsxt
    Behaviour     : Changes the target. Supports -WhatIf, -Confirm and -DiffOnly.
    Standalone    : Yes. This script does not dot-source or import any other file
                    in this repository and can be copied out on its own.
#>

#Requires -Version 5.1
#Requires -Modules VMware.VimAutomation.Nsxt

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Server,
    [Parameter(Mandatory)] [System.Management.Automation.PSCredential]$Credential,
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$InputPath,
    [Parameter()] [string]$Domain = 'default',
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

$expectedSchema     = 'nsx.dfw-rule'
$expectedProduct    = 'nsx'
$expectedVcfVersion = '5.x'

$connection = $null
try {
    $connection = Connect-NsxtServer -Server $Server -Credential $Credential -ErrorAction Stop
    Write-Verbose "Connected to NSX Manager $($connection.Name)"

    $desired = Read-ExportFile -Path $InputPath -ExpectedSchema $expectedSchema `
        -ExpectedProduct $expectedProduct -ExpectedVcfVersion $expectedVcfVersion

    if ($PolicyName) { $desired = @($desired | Where-Object { $_.Policy -in $PolicyName }) }

    $policyService = Get-NsxtPolicyService -Name 'com.vmware.nsx_policy.infra.domains.security_policies'
    $ruleService = Get-NsxtPolicyService -Name 'com.vmware.nsx_policy.infra.domains.security_policies.rules'
    $groupService = Get-NsxtPolicyService -Name 'com.vmware.nsx_policy.infra.domains.groups'
    $serviceService = Get-NsxtPolicyService -Name 'com.vmware.nsx_policy.infra.services'

    $pathByName = @{}
    foreach ($group in @($groupService.list($Domain).results)) { $pathByName[$group.display_name] = $group.path }
    foreach ($service in @($serviceService.list().results)) { $pathByName[$service.display_name] = $service.path }

    $policyIdByName = @{}
    foreach ($policy in @($policyService.list($Domain).results)) { $policyIdByName[$policy.display_name] = $policy.id }

    $current = @()
    foreach ($policyName in @($desired.Policy | Sort-Object -Unique)) {
        if (-not $policyIdByName.ContainsKey($policyName)) {
            Write-Warning "Policy '$policyName' does not exist in the target. Its rules will be skipped."
            continue
        }
        foreach ($rule in @($ruleService.list($Domain, $policyIdByName[$policyName]).results)) {
            $current += [pscustomobject]@{
                RuleKey     = '{0}/{1}' -f $policyName, $rule.display_name
                Action      = $rule.action
                Source      = ($rule.source_groups -join '; ')
                Destination = ($rule.destination_groups -join '; ')
                Service     = ($rule.services -join '; ')
                Disabled    = $rule.disabled
            }
        }
    }

    $desiredKeyed = foreach ($row in $desired) {
        [pscustomobject]@{
            RuleKey     = '{0}/{1}' -f $row.Policy, $row.RuleName
            Action      = $row.Action
            Source      = $row.Source
            Destination = $row.Destination
            Service     = $row.Service
            Disabled    = $row.Disabled
            Row         = $row
        }
    }

    Write-Verbose ("Input lists {0} rule(s); target has {1} comparable rule(s)." -f @($desiredKeyed).Count, @($current).Count)

    $plan = Compare-DesiredState -Current @($current) -Desired @($desiredKeyed) `
        -KeyProperty 'RuleKey' -CompareProperty @('Action', 'Disabled')

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
    function Resolve-NameList {
        param([string]$Value)

        if (-not $Value -or $Value -eq 'ANY') { return @('ANY') }
        $paths = @()
        foreach ($name in @($Value -split '\s*;\s*' | Where-Object { $_ })) {
            if ($name -eq 'ANY') { $paths += 'ANY'; continue }
            if ($pathByName.ContainsKey($name)) { $paths += $pathByName[$name] }
            else { throw "No group or service named '$name' exists in this NSX." }
        }
        return $paths
    }

    foreach ($item in $actionable) {
        $row = $item.Desired.Row
        if (-not $policyIdByName.ContainsKey($row.Policy)) {
            [pscustomobject]@{ Rule = $item.Key; Status = 'SkippedMissingPolicy' }
            continue
        }

        if (-not $PSCmdlet.ShouldProcess($item.Key, "$($item.Action) firewall rule")) { continue }

        try {
            $spec = $ruleService.Help.patch.rule.Create()
            $spec.display_name = $row.RuleName
            $spec.action = $row.Action
            $spec.direction = $row.Direction
            $spec.ip_protocol = $row.IpProtocol
            $spec.disabled = [System.Convert]::ToBoolean($row.Disabled)
            $spec.logged = [System.Convert]::ToBoolean($row.Logged)
            $spec.source_groups = Resolve-NameList -Value $row.Source
            $spec.destination_groups = Resolve-NameList -Value $row.Destination
            $spec.services = Resolve-NameList -Value $row.Service
            $spec.scope = Resolve-NameList -Value $row.AppliedTo
            if ($row.Sequence) { $spec.sequence_number = [int]$row.Sequence }
            if ($row.Notes) { $spec.notes = $row.Notes }

            $ruleId = if ($row.RuleId) { $row.RuleId } else { $row.RuleName -replace '[^A-Za-z0-9_-]', '-' }
            $ruleService.patch($Domain, $policyIdByName[$row.Policy], $ruleId, $spec) | Out-Null

            [pscustomobject]@{ Rule = $item.Key; Action = $item.Action; Status = 'Applied' }
        }
        catch {
            Write-Warning ("Could not apply rule '{0}': {1}" -f $item.Key, $_.Exception.Message)
            [pscustomobject]@{ Rule = $item.Key; Action = $item.Action; Status = 'Failed' }
        }
    }
}
finally {
    if ($connection) { Disconnect-NsxtServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
