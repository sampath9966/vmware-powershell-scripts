<#
.SYNOPSIS
    Creates VM classes from an export that are missing in the target and binds them to the namespaces named in the file.

.DESCRIPTION
    Creates each missing VM class with its CPU, memory and reservation settings, then adds it to
    the VM service spec of every namespace the file says should have it - where that namespace
    exists in the target.

    Namespaces named in the file that do not exist here are reported and skipped. Existing
    classes are not modified, because changing a class in use affects everything scheduled
    against it.

    Pain area addressed: #16 Config portability between environments.

.PARAMETER Server
    FQDN or IP address of the vCenter Server that hosts the Supervisor.

.PARAMETER Credential
    Credential used to authenticate to vCenter Server. Needs Namespaces privileges to read or
    change namespace configuration.

.PARAMETER InputPath
    Path to the .json (preferred) or .csv file written by the matching Export-* script. The
    envelope is validated before anything is changed.

.PARAMETER ClassName
    Limit the import to these VM class names.

.PARAMETER SkipBinding
    Create the classes but do not bind them to any namespace.

.PARAMETER DiffOnly
    Show the planned changes and exit without applying any of them. Use this first, every time.

.EXAMPLE
    PS> ./Import-SupervisorVmClass.ps1 -Server vcenter2.example.local -Credential $cred -InputPath ./vmclasses.json -DiffOnly

    Shows which VM classes are missing in the target.

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
    [Parameter()] [string[]]$ClassName,
    [Parameter()] [switch]$SkipBinding,
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

$expectedSchema     = 'supervisor.vm-class'
$expectedProduct    = 'vsphere-supervisor'
$expectedVcfVersion = '9.x'

$connection = $null
try {
    $connection = Connect-VIServer -Server $Server -Credential $Credential -ErrorAction Stop
    $cisConnection = Connect-CisServer -Server $Server -Credential $Credential -ErrorAction Stop
    Write-Verbose "Connected to vCenter Server $($connection.Name) and its Automation API endpoint"

    $desired = Read-ExportFile -Path $InputPath -ExpectedSchema $expectedSchema `
        -ExpectedProduct $expectedProduct -ExpectedVcfVersion $expectedVcfVersion

    if ($ClassName) { $desired = @($desired | Where-Object { $_.Name -in $ClassName }) }

    $classService = Get-CisService -Name 'com.vmware.vcenter.namespace_management.virtual_machine_classes' -ErrorAction Stop
    $namespaceService = Get-CisService -Name 'com.vmware.vcenter.namespaces.instances' -ErrorAction Stop

    $current = foreach ($entry in @($classService.list())) {
        [pscustomobject]@{ Name = $entry.id; CpuCount = $entry.cpu_count; MemoryMB = $entry.memory_MB }
    }

    $existingNamespaces = @(@($namespaceService.list()).namespace)
    Write-Verbose ("Input lists {0} class(es); target has {1} class(es) and {2} namespace(s)." -f `
        @($desired).Count, @($current).Count, $existingNamespaces.Count)

    $plan = Compare-DesiredState -Current @($current) -Desired @($desired) `
        -KeyProperty 'Name' -CompareProperty @('CpuCount', 'MemoryMB')

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
    foreach ($item in ($actionable | Where-Object { $_.Action -eq 'Create' })) {
        $row = $item.Desired

        if (-not $PSCmdlet.ShouldProcess("VM class '$($item.Key)'", 'Create')) { continue }

        try {
            $spec = $classService.Help.create.spec.Create()
            $spec.id = $row.Name
            $spec.cpu_count = [int64]$row.CpuCount
            $spec.memory_MB = [int64]$row.MemoryMB
            if ($row.CpuReservation) { $spec.cpu_reservation = [int64]$row.CpuReservation }
            if ($row.MemoryReservation) { $spec.memory_reservation = [int64]$row.MemoryReservation }

            $classService.create($spec) | Out-Null
            [pscustomobject]@{ VmClass = $item.Key; Status = 'Created' }
        }
        catch {
            Write-Warning ("Could not create VM class '{0}': {1}" -f $item.Key, $_.Exception.Message)
            [pscustomobject]@{ VmClass = $item.Key; Status = 'Failed' }
            continue
        }

        if ($SkipBinding) { continue }

        foreach ($namespace in @($row.BoundNamespaces -split '\s*;\s*' | Where-Object { $_ })) {
            if ($namespace -notin $existingNamespaces) {
                Write-Warning "Namespace '$namespace' does not exist here. Cannot bind '$($item.Key)' to it."
                continue
            }

            if (-not $PSCmdlet.ShouldProcess("namespace '$namespace'", "Bind VM class '$($item.Key)'")) { continue }

            try {
                $detail = $namespaceService.get($namespace)
                $classes = @($detail.vm_service_spec.vm_classes)
                if ($item.Key -in $classes) { continue }

                $updateSpec = $namespaceService.Help.update.spec.Create()
                $updateSpec.vm_service_spec = $namespaceService.Help.update.spec.vm_service_spec.Create()
                $updateSpec.vm_service_spec.vm_classes = @($classes + $item.Key)

                $namespaceService.update($namespace, $updateSpec) | Out-Null
                [pscustomobject]@{ VmClass = $item.Key; Namespace = $namespace; Status = 'Bound' }
            }
            catch {
                Write-Warning ("Could not bind '{0}' to '{1}': {2}" -f $item.Key, $namespace, $_.Exception.Message)
                [pscustomobject]@{ VmClass = $item.Key; Namespace = $namespace; Status = 'BindFailed' }
            }
        }
    }
}
finally {
    if ($cisConnection) { Disconnect-CisServer -Server $cisConnection -Confirm:$false -ErrorAction SilentlyContinue }
    if ($connection) { Disconnect-VIServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
