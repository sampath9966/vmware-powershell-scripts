<#
.SYNOPSIS
    Recreates tag categories, tags and assignments from an export, creating only what is missing.

.DESCRIPTION
    Reads a tag export and brings the target vCenter in line with it: missing categories are
    created with their original cardinality and associable types, missing tags are created
    inside them, and assignments are applied to objects that exist here by name.

    Objects named in the file that do not exist in the target are reported and skipped rather
    than failing the run, so the same file can be replayed into a smaller DR vCenter. Existing
    tags and assignments come back as Match and are left alone, which makes re-running safe.

    Pain area addressed: #16 Config portability between environments.

.PARAMETER Server
    FQDN or IP address of the vCenter Server to connect to.

.PARAMETER Credential
    Credential used to authenticate to vCenter Server.

.PARAMETER InputPath
    Path to the .json (preferred) or .csv file written by the matching Export-* script. The
    envelope is validated before anything is changed.

.PARAMETER Category
    Limit the import to these categories.

.PARAMETER SkipAssignment
    Create the categories and tags but do not attach them to any object.

.PARAMETER DiffOnly
    Show the planned changes and exit without applying any of them. Use this first, every time.

.EXAMPLE
    PS> ./Import-VcTagAssignment.ps1 -Server vcenter2.example.local -Credential $cred -InputPath ./tags.json -DiffOnly

    Shows which categories, tags and assignments are missing from the target.

.EXAMPLE
    PS> ./Import-VcTagAssignment.ps1 -Server vcenter2.example.local -Credential $cred -InputPath ./tags.json -SkipAssignment -Confirm

    Creates the tag structure only, leaving object assignment for later.

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
    [Parameter()] [string[]]$Category,
    [Parameter()] [switch]$SkipAssignment,
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

$expectedSchema     = 'vcenter.tag-assignment'
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
    # Scope every call in this script to the connection opened above. Without this,
    # PowerCLI cmdlets act on every connected server, which silently mixes inventories
    # when more than one is connected. The hashtable is cloned first because indexing
    # the inherited one would change the caller's session defaults too.
    $PSDefaultParameterValues = $PSDefaultParameterValues.Clone()
    $PSDefaultParameterValues['*:Server'] = $connection

    $desired = Read-ExportFile -Path $InputPath -ExpectedSchema $expectedSchema `
        -ExpectedProduct $expectedProduct -ExpectedVcfVersion $expectedVcfVersion

    if ($Category) { $desired = @($desired | Where-Object { $_.Category -in $Category }) }
    Write-Verbose ("Input lists {0} tag row(s)." -f @($desired).Count)

    $existingCategory = @{}
    foreach ($item in (Get-TagCategory)) { $existingCategory[$item.Name] = $item }

    $existingTag = @{}
    foreach ($item in (Get-Tag)) { $existingTag[('{0}/{1}' -f $item.Category.Name, $item.Name)] = $item }

    $existingAssignment = @{}
    foreach ($item in (Get-TagAssignment)) {
        $existingAssignment[('{0}/{1}/{2}' -f $item.Tag.Category.Name, $item.Tag.Name, $item.Entity.Name)] = $item
    }

    $plan = @()

    foreach ($group in ($desired | Group-Object Category)) {
        $name = $group.Name
        if (-not $existingCategory.ContainsKey($name)) {
            $sample = $group.Group[0]
            $plan += [pscustomobject]@{
                Key = 'category:' + $name; Action = 'Create'; ChangedProperty = 'category'
                Kind = 'Category'; Category = $name; Tag = ''; EntityName = ''
                Desired = $sample; Current = $null
            }
        }
    }

    foreach ($row in $desired) {
        if (-not $row.Tag) { continue }
        $tagKey = '{0}/{1}' -f $row.Category, $row.Tag
        if (-not $existingTag.ContainsKey($tagKey)) {
            if (-not ($plan | Where-Object { $_.Key -eq 'tag:' + $tagKey })) {
                $plan += [pscustomobject]@{
                    Key = 'tag:' + $tagKey; Action = 'Create'; ChangedProperty = 'tag'
                    Kind = 'Tag'; Category = $row.Category; Tag = $row.Tag; EntityName = ''
                    Desired = $row; Current = $null
                }
            }
        }

        if ($SkipAssignment -or -not $row.EntityName) { continue }

        $assignKey = '{0}/{1}/{2}' -f $row.Category, $row.Tag, $row.EntityName
        if (-not $existingAssignment.ContainsKey($assignKey)) {
            $plan += [pscustomobject]@{
                Key = 'assign:' + $assignKey; Action = 'Create'; ChangedProperty = 'assignment'
                Kind = 'Assignment'; Category = $row.Category; Tag = $row.Tag; EntityName = $row.EntityName
                Desired = $row; Current = $null
            }
        }
        else {
            $plan += [pscustomobject]@{
                Key = 'assign:' + $assignKey; Action = 'Match'; ChangedProperty = ''
                Kind = 'Assignment'; Category = $row.Category; Tag = $row.Tag; EntityName = $row.EntityName
                Desired = $row; Current = $existingAssignment[$assignKey]
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
    foreach ($item in ($actionable | Where-Object Kind -eq 'Category')) {
        if (-not $PSCmdlet.ShouldProcess("tag category '$($item.Category)'", 'Create')) { continue }

        $entityTypes = @()
        if ($item.Desired.EntityTypes) { $entityTypes = @($item.Desired.EntityTypes -split '\s*;\s*' | Where-Object { $_ }) }

        $newParams = @{ Name = $item.Category; Description = $item.Desired.CategoryDescription; Confirm = $false }
        if ($item.Desired.Cardinality) { $newParams['Cardinality'] = $item.Desired.Cardinality }
        if ($entityTypes) { $newParams['EntityType'] = $entityTypes }

        New-TagCategory @newParams | Out-Null
        [pscustomobject]@{ Kind = 'Category'; Name = $item.Category; Status = 'Created' }
    }

    foreach ($item in ($actionable | Where-Object Kind -eq 'Tag')) {
        if (-not $PSCmdlet.ShouldProcess("tag '$($item.Category)/$($item.Tag)'", 'Create')) { continue }

        New-Tag -Name $item.Tag -Category $item.Category -Description $item.Desired.TagDescription -Confirm:$false | Out-Null
        [pscustomobject]@{ Kind = 'Tag'; Name = '{0}/{1}' -f $item.Category, $item.Tag; Status = 'Created' }
    }

    foreach ($item in ($actionable | Where-Object Kind -eq 'Assignment')) {
        $entity = Get-Inventory -Name $item.EntityName -ErrorAction SilentlyContinue
        if (-not $entity) { $entity = Get-Datastore -Name $item.EntityName -ErrorAction SilentlyContinue }

        if (-not $entity) {
            Write-Warning "Object '$($item.EntityName)' does not exist in this vCenter. Skipping its assignment."
            [pscustomobject]@{ Kind = 'Assignment'; Name = $item.Key; Status = 'SkippedMissingObject' }
            continue
        }

        if (-not $PSCmdlet.ShouldProcess("$($item.EntityName)", "Assign tag $($item.Category)/$($item.Tag)")) { continue }

        New-TagAssignment -Tag (Get-Tag -Name $item.Tag -Category $item.Category) -Entity $entity -Confirm:$false | Out-Null
        [pscustomobject]@{ Kind = 'Assignment'; Name = $item.Key; Status = 'Assigned' }
    }
}
finally {
    if ($connection) { Disconnect-VIServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
