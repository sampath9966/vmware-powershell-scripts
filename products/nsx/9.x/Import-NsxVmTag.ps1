<#
.SYNOPSIS
    Applies NSX tags to virtual machines from an export, matching VMs by name or external id.

.DESCRIPTION
    Groups the export by VM, works out the desired tag set for each, and applies it to the
    matching VM in the target NSX. VMs whose tag set already matches come back as Match.

    The tag update API replaces the whole tag list on a VM, so by default any tag present in the
    target but not in the file is preserved by merging. Pass -Replace to make the file
    authoritative and drop extras - which is what you want when rebuilding, and not what you
    want when topping up.

    Pain area addressed: #8 DFW rules and effective membership; #16 Config portability between
    environments.

.PARAMETER Server
    FQDN or IP address of the NSX Manager to connect to.

.PARAMETER Credential
    Credential used to authenticate to NSX Manager.

.PARAMETER InputPath
    Path to the .json (preferred) or .csv file written by the matching Export-* script. The
    envelope is validated before anything is changed.

.PARAMETER MatchBy
    How to find the VM in the target: ExternalId or Name. Defaults to Name, because external ids
    differ between vCenters.

.PARAMETER Replace
    Make the file authoritative - remove tags present on the VM but absent from the file.

.PARAMETER DiffOnly
    Show the planned changes and exit without applying any of them. Use this first, every time.

.EXAMPLE
    PS> ./Import-NsxVmTag.ps1 -Server nsx-dr.example.local -Credential $cred -InputPath ./nsxtags.json -DiffOnly

    Shows which VMs would gain or lose tags.

.NOTES
    Author        : Sampath
    Product       : NSX (including vDefend) (VCF 9.x)
    Target        : VMware Cloud Foundation 9.x
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
    [Parameter()] [ValidateSet('Name','ExternalId')] [string]$MatchBy = 'Name',
    [Parameter()] [switch]$Replace,
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

$expectedSchema     = 'nsx.vm-tag'
$expectedProduct    = 'nsx'
$expectedVcfVersion = '9.x'

$connection = $null
try {
    $connection = Connect-NsxtServer -Server $Server -Credential $Credential -ErrorAction Stop
    Write-Verbose "Connected to NSX Manager $($connection.Name)"

    $desired = Read-ExportFile -Path $InputPath -ExpectedSchema $expectedSchema `
        -ExpectedProduct $expectedProduct -ExpectedVcfVersion $expectedVcfVersion

    $vmService = Get-NsxtService -Name 'com.vmware.nsx.fabric.virtual_machines'
    $tagService = Get-NsxtService -Name 'com.vmware.nsx.fabric.virtual_machines.tags'

    $targetVms = @($vmService.list().results)
    $byName = @{}
    $byExternalId = @{}
    foreach ($vm in $targetVms) {
        $byName[$vm.display_name] = $vm
        $byExternalId[$vm.external_id] = $vm
    }
    Write-Verbose ("Target NSX reports {0} virtual machine(s)." -f $targetVms.Count)

    $plan = foreach ($group in ($desired | Where-Object { $_.Tag } | Group-Object VmName)) {
        $lookup = if ($MatchBy -eq 'ExternalId') { $byExternalId } else { $byName }
        $key = if ($MatchBy -eq 'ExternalId') { $group.Group[0].ExternalId } else { $group.Name }

        if (-not $lookup.ContainsKey($key)) {
            Write-Warning "VM '$($group.Name)' is not present in this NSX. Skipping."
            continue
        }

        $vm = $lookup[$key]
        $wanted = @($group.Group | ForEach-Object { '{0}={1}' -f $_.Scope, $_.Tag } | Sort-Object -Unique)
        $have = @(@($vm.tags) | ForEach-Object { '{0}={1}' -f $_.scope, $_.tag } | Sort-Object -Unique)

        $final = if ($Replace) { $wanted } else { @($wanted + $have | Sort-Object -Unique) }
        $differs = (($final -join '|') -ne ($have -join '|'))

        [pscustomobject]@{
            Key             = $group.Name
            Action          = if ($differs) { 'Update' } else { 'Match' }
            ChangedProperty = if ($differs) { 'tags' } else { '' }
            VmName          = $group.Name
            ExternalId      = $vm.external_id
            CurrentTags     = ($have -join '; ')
            DesiredTags     = ($final -join '; ')
            Desired         = $group.Group
            Current         = $vm
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
    foreach ($item in $actionable) {
        $target = "{0}: '{1}' -> '{2}'" -f $item.VmName, $item.CurrentTags, $item.DesiredTags

        if (-not $PSCmdlet.ShouldProcess($target, 'Set NSX tags')) { continue }

        try {
            $spec = $tagService.Help.update.virtual_machine_tags_update.Create()
            $spec.external_id = $item.ExternalId

            $tagList = @()
            foreach ($pair in @($item.DesiredTags -split '\s*;\s*' | Where-Object { $_ })) {
                $scope, $value = $pair -split '=', 2
                $tag = $tagService.Help.update.virtual_machine_tags_update.tags.Element.Create()
                $tag.scope = $scope
                $tag.tag = $value
                $tagList += $tag
            }
            $spec.tags = $tagList

            $tagService.update($spec) | Out-Null
            [pscustomobject]@{ VmName = $item.VmName; Tags = $item.DesiredTags; Status = 'Applied' }
        }
        catch {
            Write-Warning ("Could not tag '{0}': {1}" -f $item.VmName, $_.Exception.Message)
            [pscustomobject]@{ VmName = $item.VmName; Tags = $item.DesiredTags; Status = 'Failed' }
        }
    }
}
finally {
    if ($connection) { Disconnect-NsxtServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
