<#
.SYNOPSIS
    Imports .package files for the packages listed in an export that are missing from the target.

.DESCRIPTION
    Compares the packages in the file against the target and imports the missing ones from
    -PackageDirectory. A package with no matching file on disk is reported and skipped.

    Import overwrites content with the same id, so -OverwriteExisting is required to touch
    anything that is already there. Without it, existing packages are left alone even when the
    file holds a newer version.

    Pain area addressed: #16 Config portability between environments.

.PARAMETER Server
    FQDN or IP address of the VCF Operations orchestrator appliance.

.PARAMETER Credential
    Credential used to authenticate to the orchestrator API.

.PARAMETER InputPath
    Path to the .json (preferred) or .csv file written by the matching Export-* script. The
    envelope is validated before anything is changed.

.PARAMETER PackageDirectory
    Directory holding the .package files to import.

.PARAMETER OverwriteExisting
    Also re-import packages that already exist in the target, overwriting their content.

.PARAMETER IgnoreInvalidCertificate
    Accept an untrusted or self-signed certificate on the target endpoint. Use only in lab
    environments.

.PARAMETER DiffOnly
    Show the planned changes and exit without applying any of them. Use this first, every time.

.EXAMPLE
    PS> ./Import-OrchestratorPackage.ps1 -Server vro2.example.local -Credential $cred -InputPath ./packages.json -PackageDirectory ./packages -DiffOnly

    Shows which packages would be imported.

.NOTES
    Author        : Sampath
    Product       : Aria Automation Orchestrator (VCF 5.x)
    Target        : VMware Cloud Foundation 5.x
    Modules       : None (uses Invoke-RestMethod)
    Behaviour     : Changes the target. Supports -WhatIf, -Confirm and -DiffOnly.
    Standalone    : Yes. This script does not dot-source or import any other file
                    in this repository and can be copied out on its own.
#>

#Requires -Version 5.1

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Server,
    [Parameter(Mandatory)] [System.Management.Automation.PSCredential]$Credential,
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$InputPath,
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$PackageDirectory,
    [Parameter()] [switch]$OverwriteExisting,
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

$expectedSchema     = 'orchestrator.package'
$expectedProduct    = 'vcf-operations-orchestrator'
$expectedVcfVersion = '5.x'

$headers = $null
try {
    $restCommon = @{ ContentType = 'application/json' }

    if ($PSVersionTable.PSVersion.Major -lt 6) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    }

    if ($IgnoreInvalidCertificate) {
        if ($PSVersionTable.PSVersion.Major -ge 6) {
            $restCommon['SkipCertificateCheck'] = $true
        }
        else {
            Write-Warning 'Certificate validation is disabled for this session. Use this only in lab environments.'
            [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        }
    }

    $baseUri = "https://$Server"
    $pair = '{0}:{1}' -f $Credential.UserName, $Credential.GetNetworkCredential().Password
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair))
    $headers = @{ Accept = 'application/json'; Authorization = "Basic $encoded" }
    Write-Verbose "Prepared basic authentication for $Server"

    if (-not (Test-Path -LiteralPath $PackageDirectory)) { throw "Package directory not found: $PackageDirectory" }

    $desired = Read-ExportFile -Path $InputPath -ExpectedSchema $expectedSchema `
        -ExpectedProduct $expectedProduct -ExpectedVcfVersion $expectedVcfVersion

    $response = Invoke-RestMethod @restCommon -Method Get -Uri "$baseUri/vco/api/packages" -Headers $headers
    $existingNames = @()
    foreach ($package in @($response.link)) {
        foreach ($attribute in @($package.attributes)) {
            if ($attribute.name -eq 'name') { $existingNames += $attribute.value }
        }
    }

    Write-Verbose ("Input lists {0} package(s); target has {1}." -f @($desired).Count, $existingNames.Count)

    $plan = foreach ($row in @($desired)) {
        $exists = $row.Name -in $existingNames
        $action = if (-not $exists) { 'Create' } elseif ($OverwriteExisting) { 'Update' } else { 'Match' }

        $file = Join-Path $PackageDirectory ($row.Name + '.package')
        $hasFile = Test-Path -LiteralPath $file

        if ($action -ne 'Match' -and -not $hasFile) {
            Write-Warning "No file '$($row.Name).package' in $PackageDirectory."
        }

        [pscustomobject]@{
            Key             = $row.Name
            Action          = $action
            ChangedProperty = 'package'
            PackageFile     = if ($hasFile) { $file } else { $null }
            Desired         = $row
            Current         = $null
        }
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
        if (-not $item.PackageFile) {
            [pscustomobject]@{ Package = $item.Key; Status = 'SkippedNoFile' }
            continue
        }

        if (-not $PSCmdlet.ShouldProcess("package '$($item.Key)'", $item.Action)) { continue }

        try {
            $uri = '{0}/vco/api/content/packages?overwrite={1}' -f $baseUri, $OverwriteExisting.ToString().ToLowerInvariant()
            $uploadHeaders = @{ Authorization = $headers.Authorization }

            Invoke-RestMethod -Method Post -Uri $uri -Headers $uploadHeaders `
                -InFile $item.PackageFile -ContentType 'application/octet-stream' | Out-Null

            [pscustomobject]@{ Package = $item.Key; Action = $item.Action; Status = 'Imported' }
        }
        catch {
            Write-Warning ("Could not import package '{0}': {1}" -f $item.Key, $_.Exception.Message)
            [pscustomobject]@{ Package = $item.Key; Action = $item.Action; Status = 'Failed' }
        }
    }
}
finally {
    $headers = $null
}
