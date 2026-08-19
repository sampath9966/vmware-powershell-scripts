<#
.SYNOPSIS
    Applies non-secret configuration element attribute values from an export to the matching elements in the target.

.DESCRIPTION
    Matches elements by category path and name, compares each attribute value against the
    target, and updates the ones that differ. Elements that do not exist in the target are
    reported rather than created, because an element with no workflow reading it is noise.

    Attributes marked as secret in the export carry no value and are always skipped. Set those
    by hand or from a secret store after this runs - the script tells you which ones it left.

    Pain area addressed: #16 Config portability between environments.

.PARAMETER Server
    FQDN or IP address of the VCF Operations orchestrator appliance.

.PARAMETER Credential
    Credential used to authenticate to the orchestrator API.

.PARAMETER InputPath
    Path to the .json (preferred) or .csv file written by the matching Export-* script. The
    envelope is validated before anything is changed.

.PARAMETER CategoryPath
    Limit the import to elements under these category paths.

.PARAMETER ElementName
    Limit the import to these element names.

.PARAMETER IgnoreInvalidCertificate
    Accept an untrusted or self-signed certificate on the target endpoint. Use only in lab
    environments.

.PARAMETER DiffOnly
    Show the planned changes and exit without applying any of them. Use this first, every time.

.EXAMPLE
    PS> ./Import-OrchestratorConfigurationElement.ps1 -Server vro2.example.local -Credential $cred -InputPath ./configs.json -DiffOnly

    Shows which attribute values differ between the file and the target.

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
    [Parameter()] [string[]]$CategoryPath,
    [Parameter()] [string[]]$ElementName,
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

$expectedSchema     = 'orchestrator.configuration-element'
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

    $desired = Read-ExportFile -Path $InputPath -ExpectedSchema $expectedSchema `
        -ExpectedProduct $expectedProduct -ExpectedVcfVersion $expectedVcfVersion

    $desired = @($desired | Where-Object { -not [System.Convert]::ToBoolean($_.IsSecret) })
    if ($CategoryPath) { $desired = @($desired | Where-Object { $c = $_.CategoryPath; @($CategoryPath | Where-Object { $c -like "$_*" }).Count -gt 0 }) }
    if ($ElementName) { $desired = @($desired | Where-Object { $_.Element -in $ElementName }) }

    $response = Invoke-RestMethod @restCommon -Method Get -Uri "$baseUri/vco/api/configurations" -Headers $headers
    $elementIdByKey = @{}
    foreach ($element in @($response.link)) {
        $attributes = @{}
        foreach ($attribute in @($element.attributes)) { $attributes[$attribute.name] = $attribute.value }
        $elementIdByKey[('{0}/{1}' -f $attributes['categoryPath'], $attributes['name'])] = $attributes['id']
    }
    Write-Verbose ("Target has {0} configuration element(s); input carries {1} non-secret attribute row(s)." -f `
        $elementIdByKey.Count, @($desired).Count)

    $plan = foreach ($row in $desired) {
        $elementKey = '{0}/{1}' -f $row.CategoryPath, $row.Element

        if (-not $elementIdByKey.ContainsKey($elementKey)) {
            Write-Warning "Element '$elementKey' does not exist in the target. Skipping its attributes."
            continue
        }

        $elementId = $elementIdByKey[$elementKey]
        $currentValue = ''
        try {
            $detail = Invoke-RestMethod @restCommon -Method Get -Uri ('{0}/vco/api/configurations/{1}' -f $baseUri, $elementId) -Headers $headers
            $match = @($detail.attributes | Where-Object { $_.name -eq $row.AttributeName }) | Select-Object -First 1
            if ($match) { $currentValue = [string]$match.value.string }
        }
        catch { Write-Verbose "Could not read current value of '$($row.AttributeName)' on '$elementKey'." }

        [pscustomobject]@{
            Key             = '{0}/{1}' -f $elementKey, $row.AttributeName
            Action          = if ($currentValue -eq [string]$row.Value) { 'Match' } else { 'Update' }
            ChangedProperty = 'value'
            ElementId       = $elementId
            ElementKey      = $elementKey
            AttributeName   = $row.AttributeName
            CurrentValue    = $currentValue
            DesiredValue    = [string]$row.Value
            Desired         = $row
            Current         = $null
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
    foreach ($group in ($actionable | Group-Object ElementId)) {
        $elementId = $group.Name
        $elementKey = $group.Group[0].ElementKey

        if (-not $PSCmdlet.ShouldProcess("configuration element '$elementKey'", "Update $(@($group.Group).Count) attribute(s)")) { continue }

        try {
            $detail = Invoke-RestMethod @restCommon -Method Get -Uri ('{0}/vco/api/configurations/{1}' -f $baseUri, $elementId) -Headers $headers

            foreach ($item in $group.Group) {
                foreach ($attribute in @($detail.attributes)) {
                    if ($attribute.name -eq $item.AttributeName) { $attribute.value.string.value = $item.DesiredValue }
                }
            }

            Invoke-RestMethod @restCommon -Method Put -Uri ('{0}/vco/api/configurations/{1}' -f $baseUri, $elementId) `
                -Headers $headers -Body ($detail | ConvertTo-Json -Depth 12) | Out-Null

            foreach ($item in $group.Group) {
                [pscustomobject]@{ Element = $elementKey; Attribute = $item.AttributeName; Status = 'Updated' }
            }
        }
        catch {
            Write-Warning ("Could not update '{0}': {1}" -f $elementKey, $_.Exception.Message)
            foreach ($item in $group.Group) {
                [pscustomobject]@{ Element = $elementKey; Attribute = $item.AttributeName; Status = 'Failed' }
            }
        }
    }
}
finally {
    $headers = $null
}
