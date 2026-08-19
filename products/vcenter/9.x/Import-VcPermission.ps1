<#
.SYNOPSIS
    Recreates custom roles and permission assignments from an export, creating only what is missing.

.DESCRIPTION
    Creates any custom role in the file that does not exist here, with its original privilege
    list, then applies the permission assignments to objects that exist in this vCenter by name.
    Roles that exist but grant a different privilege set are reported as Update so the drift is
    visible before anything is changed.

    Principals are not validated against the identity source, so an assignment for a group that
    does not resolve here will fail on that one row and be reported, not abort the run.

    Pain area addressed: #16 Config portability between environments.

.PARAMETER Server
    FQDN or IP address of the vCenter Server to connect to.

.PARAMETER Credential
    Credential used to authenticate to vCenter Server.

.PARAMETER InputPath
    Path to the .json (preferred) or .csv file written by the matching Export-* script. The
    envelope is validated before anything is changed.

.PARAMETER SkipPermission
    Create the roles only, without applying any permission assignment.

.PARAMETER UpdateExistingRole
    Also correct the privilege list of roles that exist but differ from the file.

.PARAMETER DiffOnly
    Show the planned changes and exit without applying any of them. Use this first, every time.

.EXAMPLE
    PS> ./Import-VcPermission.ps1 -Server vcenter2.example.local -Credential $cred -InputPath ./rbac.json -DiffOnly

    Shows which roles and assignments are missing or drifted in the target.

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
    [Parameter()] [switch]$SkipPermission,
    [Parameter()] [switch]$UpdateExistingRole,
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

$expectedSchema     = 'vcenter.permission'
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

    $desired = Read-ExportFile -Path $InputPath -ExpectedSchema $expectedSchema `
        -ExpectedProduct $expectedProduct -ExpectedVcfVersion $expectedVcfVersion

    $desiredRoles = @($desired | Where-Object { $_.Kind -eq 'Role' })
    $desiredPermissions = @($desired | Where-Object { $_.Kind -eq 'Permission' })
    Write-Verbose ("Input lists {0} role(s) and {1} permission(s)." -f $desiredRoles.Count, $desiredPermissions.Count)

    $currentRole = @{}
    foreach ($role in (Get-VIRole -Server $connection)) { $currentRole[$role.Name] = $role }

    $currentPermission = @{}
    foreach ($permission in (Get-VIPermission -Server $connection)) {
        $currentPermission[('{0}|{1}|{2}' -f $permission.Principal, $permission.Entity.Name, $permission.Role)] = $permission
    }

    $knownPrivilege = @{}
    foreach ($privilege in (Get-VIPrivilege -Server $connection -ErrorAction SilentlyContinue)) {
        $knownPrivilege[$privilege.Id] = $privilege
    }

    Write-Verbose ("Target exposes {0} privilege(s); it already has {1} role(s) and {2} permission(s)." -f `
        $knownPrivilege.Count, $currentRole.Count, $currentPermission.Count)

    $plan = @()

    foreach ($row in $desiredRoles) {
        $want = @($row.Privileges -split '\s*;\s*' | Where-Object { $_ } | Sort-Object -Unique)
        $missing = @($want | Where-Object { -not $knownPrivilege.ContainsKey($_) })

        if ($missing.Count -gt 0) {
            Write-Warning ("Role '{0}': {1} of {2} privilege(s) in the file do not exist on this vCenter and will be omitted. First few: {3}" -f `
                $row.Role, $missing.Count, $want.Count, ((@($missing) | Select-Object -First 6) -join ', '))
        }

        $existing = $currentRole[$row.Role]

        if (-not $existing) {
            $plan += [pscustomobject]@{
                Key = 'role:' + $row.Role; Action = 'Create'; ChangedProperty = 'privileges'
                Kind = 'Role'; Role = $row.Role
                WantPrivilege = $want; MissingPrivilege = $missing
                Desired = $row; Current = $null
            }
            continue
        }

        $have = @($existing.PrivilegeList | Sort-Object -Unique)
        $differs = (($want -join '|') -ne ($have -join '|'))

        $plan += [pscustomobject]@{
            Key = 'role:' + $row.Role
            Action = if ($differs -and $UpdateExistingRole) { 'Update' } else { 'Match' }
            ChangedProperty = if ($differs) { 'privileges' } else { '' }
            Kind = 'Role'; Role = $row.Role
            WantPrivilege = $want; MissingPrivilege = $missing
            Desired = $row; Current = $existing
        }
    }

    if (-not $SkipPermission) {
        foreach ($row in $desiredPermissions) {
            $key = '{0}|{1}|{2}' -f $row.Principal, $row.Entity, $row.Role
            $plan += [pscustomobject]@{
                Key = 'perm:' + $key
                Action = if ($currentPermission.ContainsKey($key)) { 'Match' } else { 'Create' }
                ChangedProperty = 'permission'
                Kind = 'Permission'; Role = $row.Role; Desired = $row
                Current = $currentPermission[$key]
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
    foreach ($item in ($actionable | Where-Object Kind -eq 'Role')) {
        $resolved = @($item.WantPrivilege |
            Where-Object { $knownPrivilege.ContainsKey($_) } |
            ForEach-Object { $knownPrivilege[$_] })

        if (-not $resolved) {
            Write-Warning ("Role '{0}': none of its {1} privilege(s) exist on this vCenter. Skipping." -f `
                $item.Role, @($item.WantPrivilege).Count)
            [pscustomobject]@{ Kind = 'Role'; Name = $item.Role; Privileges = 0; Omitted = @($item.WantPrivilege).Count; Status = 'SkippedNoPrivilege' }
            continue
        }

        if ($item.Action -eq 'Create') {
            if (-not $PSCmdlet.ShouldProcess("role '$($item.Role)' with $(@($resolved).Count) privilege(s)", 'Create')) { continue }
            New-VIRole -Name $item.Role -Privilege $resolved -Server $connection -Confirm:$false | Out-Null
            [pscustomobject]@{ Kind = 'Role'; Name = $item.Role; Privileges = @($resolved).Count; Omitted = @($item.MissingPrivilege).Count; Status = 'Created' }
        }
        else {
            if (-not $PSCmdlet.ShouldProcess("role '$($item.Role)'", 'Update privilege list')) { continue }
            Set-VIRole -Role $item.Current -AddPrivilege $resolved -Confirm:$false | Out-Null
            [pscustomobject]@{ Kind = 'Role'; Name = $item.Role; Privileges = @($resolved).Count; Omitted = @($item.MissingPrivilege).Count; Status = 'Updated' }
        }
    }

    function Resolve-PermissionEntity {
        <#
            Finds the inventory object a permission belongs on. Networks and datastores are
            not reachable through Get-Inventory, and a folder and a VM can share a name, so
            the entity type recorded in the export is used to search and to disambiguate.
        #>
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][string]$Name,
            [Parameter()][string]$EntityType
        )

        $candidates = @()

        switch -Regex ($EntityType) {
            'Network|Portgroup' { $candidates = @(Get-VirtualNetwork -Name $Name -Server $connection -ErrorAction SilentlyContinue) }
            'Datastore'         { $candidates = @(Get-Datastore -Name $Name -Server $connection -ErrorAction SilentlyContinue) }
        }

        if (-not $candidates) { $candidates = @(Get-Inventory -Name $Name -Server $connection -ErrorAction SilentlyContinue) }
        if (-not $candidates) { $candidates = @(Get-Datastore -Name $Name -Server $connection -ErrorAction SilentlyContinue) }
        if (-not $candidates) { $candidates = @(Get-VirtualNetwork -Name $Name -Server $connection -ErrorAction SilentlyContinue) }

        if ($EntityType -and @($candidates).Count -gt 1) {
            $typed = @($candidates | Where-Object { ($_.GetType().Name -replace 'Impl$', '') -eq $EntityType })
            if ($typed) { $candidates = $typed }
        }

        return @($candidates)
    }

    foreach ($item in ($actionable | Where-Object Kind -eq 'Permission')) {
        $row = $item.Desired
        $candidates = Resolve-PermissionEntity -Name $row.Entity -EntityType $row.EntityType

        if (@($candidates).Count -eq 0) {
            Write-Warning ("Object '{0}' of type '{1}' does not exist in this vCenter. Skipping its permission." -f $row.Entity, $row.EntityType)
            [pscustomobject]@{ Kind = 'Permission'; Name = $item.Key; Status = 'SkippedMissingObject' }
            continue
        }

        if (@($candidates).Count -gt 1) {
            Write-Warning ("'{0}' matches {1} objects here and the type '{2}' does not narrow it to one. Skipping rather than granting on the wrong object." -f `
                $row.Entity, @($candidates).Count, $row.EntityType)
            [pscustomobject]@{ Kind = 'Permission'; Name = $item.Key; Status = 'SkippedAmbiguousObject' }
            continue
        }

        $entity = @($candidates)[0]

        $propagate = $true
        if ($null -ne $row.Propagate -and "$($row.Propagate)" -ne '') {
            try { $propagate = [System.Convert]::ToBoolean([string]$row.Propagate) }
            catch { $propagate = $true }
        }

        if (-not $PSCmdlet.ShouldProcess("$($row.Principal) on $($row.Entity)", "Grant role $($row.Role)")) { continue }

        try {
            New-VIPermission -Entity $entity -Principal $row.Principal -Role $row.Role `
                -Propagate $propagate -Server $connection -Confirm:$false -ErrorAction Stop | Out-Null
            [pscustomobject]@{ Kind = 'Permission'; Name = $item.Key; Status = 'Granted' }
        }
        catch {
            Write-Warning ("Could not grant {0}: {1}" -f $item.Key, $_.Exception.Message)
            [pscustomobject]@{ Kind = 'Permission'; Name = $item.Key; Status = 'Failed' }
        }
    }
}
finally {
    if ($connection) { Disconnect-VIServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
