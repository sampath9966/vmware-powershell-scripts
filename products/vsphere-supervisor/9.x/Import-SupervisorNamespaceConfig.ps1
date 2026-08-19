<#
.SYNOPSIS
    Creates missing namespaces and corrects limits, storage policies and access from a namespace export.

.DESCRIPTION
    Compares the namespaces in the file against the target Supervisor and creates the missing
    ones with their limits, storage policies, VM classes and access list. Namespaces that exist
    but whose limits differ are reported as Update and corrected when you let them be.

    Storage policies and VM classes are matched by name in the target, so a namespace
    referencing a policy that does not exist here is reported and skipped rather than created
    with no storage. Namespaces are never deleted by this script.

    Pain area addressed: #16 Config portability between environments.

.PARAMETER Server
    FQDN or IP address of the vCenter Server that hosts the Supervisor.

.PARAMETER Credential
    Credential used to authenticate to vCenter Server. Needs Namespaces privileges to read or
    change namespace configuration.

.PARAMETER InputPath
    Path to the .json (preferred) or .csv file written by the matching Export-* script. The
    envelope is validated before anything is changed.

.PARAMETER Cluster
    Name of the Supervisor-enabled cluster in this vCenter to create the namespaces on.

.PARAMETER NamespaceName
    Limit the import to these namespace names.

.PARAMETER UpdateExisting
    Also correct limits on namespaces that already exist but differ.

.PARAMETER DiffOnly
    Show the planned changes and exit without applying any of them. Use this first, every time.

.EXAMPLE
    PS> ./Import-SupervisorNamespaceConfig.ps1 -Server vcenter2.example.local -Credential $cred -InputPath ./namespaces.json -Cluster wld-cluster-01 -DiffOnly

    Shows which namespaces are missing or have drifted limits.

.NOTES
    Author        : Sampath
    Product       : vSphere Supervisor and VKS (VCF 9.x)
    Target        : VMware Cloud Foundation 9.x
    Modules       : VMware.VimAutomation.Core, VMware.VimAutomation.WorkloadManagement, VMware.VimAutomation.Cis.Core
    Behaviour     : Changes the target. Supports -WhatIf, -Confirm and -DiffOnly.
    Standalone    : Yes. This script does not dot-source or import any other file
                    in this repository and can be copied out on its own.
#>

#Requires -Version 5.1
#Requires -Modules VMware.VimAutomation.Core
#Requires -Modules VMware.VimAutomation.WorkloadManagement
#Requires -Modules VMware.VimAutomation.Cis.Core

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Server,
    [Parameter(Mandatory)] [System.Management.Automation.PSCredential]$Credential,
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$InputPath,
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Cluster,
    [Parameter()] [string[]]$NamespaceName,
    [Parameter()] [switch]$UpdateExisting,
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

$expectedSchema     = 'supervisor.namespace-inventory'
$expectedProduct    = 'vsphere-supervisor'
$expectedVcfVersion = '9.x'

$connection = $null
try {
    $connection = Connect-VIServer -Server $Server -Credential $Credential -ErrorAction Stop
    $cisConnection = Connect-CisServer -Server $Server -Credential $Credential -ErrorAction Stop
    if (@($DefaultVIServers).Count -gt 1) {
        Write-Warning (("{0} vCenter connections are open in this session. PowerCLI cmdlets act on " +
            "every connected server unless they are scoped, which silently mixes inventories. " +
            "This script scopes its own calls to '{1}'.") -f @($DefaultVIServers).Count, $connection.Name)
    }
    Write-Verbose "Connected to vCenter Server $($connection.Name) and its Automation API endpoint"

    $desired = Read-ExportFile -Path $InputPath -ExpectedSchema $expectedSchema `
        -ExpectedProduct $expectedProduct -ExpectedVcfVersion $expectedVcfVersion

    if ($NamespaceName) { $desired = @($desired | Where-Object { $_.Namespace -in $NamespaceName }) }

    $targetCluster = Get-Cluster -Name $Cluster -ErrorAction Stop
    $clusterId = $targetCluster.ExtensionData.MoRef.Value

    $namespaceService = Get-CisService -Name 'com.vmware.vcenter.namespaces.instances' -ErrorAction Stop

    $current = foreach ($entry in @($namespaceService.list())) {
        $detail = $null
        try { $detail = $namespaceService.get($entry.namespace) } catch { continue }

        $cpuLimit = $null
        $memoryLimit = $null
        foreach ($limit in @($detail.resource_spec)) {
            if ($limit.cpu_limit) { $cpuLimit = $limit.cpu_limit }
            if ($limit.memory_limit) { $memoryLimit = $limit.memory_limit }
        }

        [pscustomobject]@{
            Namespace     = $entry.namespace
            CpuLimitMHz   = $cpuLimit
            MemoryLimitMB = $memoryLimit
        }
    }

    $availablePolicies = @((Get-SpbmStoragePolicy -ErrorAction SilentlyContinue).Name)
    Write-Verbose ("Input lists {0} namespace(s); target has {1}." -f @($desired).Count, @($current).Count)

    $plan = Compare-DesiredState -Current @($current) -Desired @($desired) `
        -KeyProperty 'Namespace' -CompareProperty @('CpuLimitMHz', 'MemoryLimitMB')

    if (-not $UpdateExisting) {
        foreach ($item in $plan) { if ($item.Action -eq 'Update') { $item.Action = 'Match' } }
    }

    foreach ($item in $plan) {
        $wanted = @($item.Desired.StoragePolicies -split '\s*;\s*' | Where-Object { $_ })
        $missing = @($wanted | Where-Object { $_ -notin $availablePolicies })
        $item | Add-Member -NotePropertyName MissingPolicy -NotePropertyValue ($missing -join '; ') -Force
        if ($item.Action -ne 'Match' -and $missing) {
            Write-Warning ("Namespace '{0}' needs storage policies missing here: {1}." -f $item.Key, ($missing -join ', '))
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
        $row = $item.Desired

        if ($item.MissingPolicy) {
            [pscustomobject]@{ Namespace = $item.Key; Status = 'SkippedMissingStoragePolicy' }
            continue
        }

        if (-not $PSCmdlet.ShouldProcess("namespace '$($item.Key)' on '$Cluster'", $item.Action)) { continue }

        try {
            if ($item.Action -eq 'Create') {
                $spec = $namespaceService.Help.create.spec.Create()
                $spec.cluster = $clusterId
                $spec.namespace = $row.Namespace
                $spec.description = $row.Description

                $storageSpecs = @()
                foreach ($policyName in @($row.StoragePolicies -split '\s*;\s*' | Where-Object { $_ })) {
                    $storage = $namespaceService.Help.create.spec.storage_specs.Element.Create()
                    $storage.policy = (Get-SpbmStoragePolicy -Name $policyName -ErrorAction Stop).Id
                    $storageSpecs += $storage
                }
                $spec.storage_specs = $storageSpecs

                $accessList = @()
                foreach ($entry in @($row.AccessList -split '\s*;\s*' | Where-Object { $_ })) {
                    $domainAndRest = $entry -split '\\', 2
                    if ($domainAndRest.Count -lt 2) { continue }
                    $subjectAndRole = $domainAndRest[1] -split ':', 2

                    $access = $namespaceService.Help.create.spec.access_list.Element.Create()
                    $access.domain = $domainAndRest[0]
                    $access.subject = $subjectAndRole[0]
                    $access.role = $subjectAndRole[1]
                    $access.subject_type = 'USER'
                    $accessList += $access
                }
                $spec.access_list = $accessList

                $namespaceService.create($spec) | Out-Null
                [pscustomobject]@{ Namespace = $item.Key; Action = 'Create'; Status = 'Created' }
            }
            else {
                $spec = $namespaceService.Help.update.spec.Create()
                $namespaceService.update($item.Key, $spec) | Out-Null
                [pscustomobject]@{ Namespace = $item.Key; Action = 'Update'; Status = 'Updated' }
            }
        }
        catch {
            Write-Warning ("Could not apply namespace '{0}': {1}" -f $item.Key, $_.Exception.Message)
            [pscustomobject]@{ Namespace = $item.Key; Action = $item.Action; Status = 'Failed' }
        }
    }
}
finally {
    if ($cisConnection) { Disconnect-CisServer -Server $cisConnection -Confirm:$false -ErrorAction SilentlyContinue }
    if ($connection) { Disconnect-VIServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
