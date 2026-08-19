<#
.SYNOPSIS
    Installs content packs listed in an export that are missing from the target, from a directory of .vlcp files.

.DESCRIPTION
    Compares the packs in the file against the target and installs the missing ones from
    -PackDirectory, matching a .vlcp file to a pack by namespace or name.

    Content pack files are not carried in the export - they are binaries - so this needs the
    directory of .vlcp files alongside. A pack with no matching file is reported and skipped.

    Pain area addressed: #16 Config portability between environments.

.PARAMETER Server
    FQDN or IP address of the VCF Operations for Logs node.

.PARAMETER Credential
    Credential used to authenticate to the Logs API.

.PARAMETER InputPath
    Path to the .json (preferred) or .csv file written by the matching Export-* script. The
    envelope is validated before anything is changed.

.PARAMETER PackDirectory
    Directory holding the .vlcp content pack files to install from.

.PARAMETER Namespace
    Limit the import to these namespaces.

.PARAMETER IgnoreInvalidCertificate
    Accept an untrusted or self-signed certificate on the target endpoint. Use only in lab
    environments.

.PARAMETER DiffOnly
    Show the planned changes and exit without applying any of them. Use this first, every time.

.EXAMPLE
    PS> ./Import-LogsContentPack.ps1 -Server logs2.example.local -Credential $cred -InputPath ./packs.json -PackDirectory ./vlcp -DiffOnly

    Shows which packs are missing and which have a file available.

.NOTES
    Author        : Sampath
    Product       : Aria Operations for Logs (VCF 5.x)
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
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$PackDirectory,
    [Parameter()] [string[]]$Namespace,
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

$expectedSchema     = 'logs.content-pack'
$expectedProduct    = 'vcf-operations-for-logs'
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
    $authBody = @{ provider = 'Local'; username = $Credential.UserName; password = $Credential.GetNetworkCredential().Password } | ConvertTo-Json
    $authResponse = Invoke-RestMethod @restCommon -Method Post -Uri "$baseUri/api/v2/sessions" -Body $authBody
    $headers = @{ Accept = 'application/json'; Authorization = "Bearer $($authResponse.sessionId)" }
    Write-Verbose "Acquired a Logs API session from $Server"

    if (-not (Test-Path -LiteralPath $PackDirectory)) { throw "Pack directory not found: $PackDirectory" }

    $desired = Read-ExportFile -Path $InputPath -ExpectedSchema $expectedSchema `
        -ExpectedProduct $expectedProduct -ExpectedVcfVersion $expectedVcfVersion

    if ($Namespace) { $desired = @($desired | Where-Object { $_.Namespace -in $Namespace }) }

    $response = Invoke-RestMethod @restCommon -Method Get -Uri "$baseUri/api/v2/content/contentpacks" -Headers $headers
    $current = foreach ($pack in @($response.contentPackMetadataList)) {
        [pscustomobject]@{ Namespace = $pack.namespace; Version = $pack.contentVersion }
    }

    Write-Verbose ("Input lists {0} pack(s); target has {1}." -f @($desired).Count, @($current).Count)

    $files = @(Get-ChildItem -LiteralPath $PackDirectory -Filter '*.vlcp' -ErrorAction SilentlyContinue)

    $plan = Compare-DesiredState -Current @($current) -Desired @($desired) `
        -KeyProperty 'Namespace' -CompareProperty @('Version')

    foreach ($item in $plan) {
        $candidate = $files |
            Where-Object { $_.BaseName -eq $item.Key -or $_.BaseName -like ('*' + $item.Key + '*') } |
            Select-Object -First 1

        $packFile = $null
        if ($candidate) { $packFile = $candidate.FullName }

        $item | Add-Member -NotePropertyName PackFile -NotePropertyValue $packFile -Force

        if ($item.Action -ne 'Match' -and -not $packFile) {
            Write-Warning "No .vlcp file found for namespace '$($item.Key)' in $PackDirectory."
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
        if (-not $item.PackFile) {
            [pscustomobject]@{ Namespace = $item.Key; Status = 'SkippedNoFile' }
            continue
        }

        if (-not $PSCmdlet.ShouldProcess("content pack '$($item.Key)'", 'Install')) { continue }

        try {
            $content = [Convert]::ToBase64String([IO.File]::ReadAllBytes($item.PackFile))
            $payload = @{ contentPack = $content } | ConvertTo-Json

            Invoke-RestMethod @restCommon -Method Post -Uri "$baseUri/api/v2/content/contentpack" `
                -Headers $headers -Body $payload | Out-Null

            [pscustomobject]@{ Namespace = $item.Key; File = (Split-Path $item.PackFile -Leaf); Status = 'Installed' }
        }
        catch {
            Write-Warning ("Could not install '{0}': {1}" -f $item.Key, $_.Exception.Message)
            [pscustomobject]@{ Namespace = $item.Key; File = (Split-Path $item.PackFile -Leaf); Status = 'Failed' }
        }
    }
}
finally {
    $headers = $null
}
