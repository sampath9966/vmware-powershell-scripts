<#
.SYNOPSIS
    Creates the alert definitions from an export that do not already exist in the target instance.

.DESCRIPTION
    Compares definitions in the file against the target by name and creates the missing ones,
    binding each to the symptom definitions that already exist there by name.

    Symptom definitions are not created by this script - a symptom refers to metrics that must
    exist on the target adapter, and inventing them blind produces definitions that never fire.
    A definition whose symptoms are missing is reported and skipped, so the gap is explicit.

    Pain area addressed: #13 Alarm noise and audit-trail extraction; #16 Config portability
    between environments.

.PARAMETER Server
    FQDN or IP address of the VCF Operations node.

.PARAMETER Credential
    Credential used to authenticate to the VCF Operations API.

.PARAMETER InputPath
    Path to the .json (preferred) or .csv file written by the matching Export-* script. The
    envelope is validated before anything is changed.

.PARAMETER Name
    Limit the import to these definition names.

.PARAMETER PageSize
    How many definitions to request per API call. Defaults to 500.

.PARAMETER IgnoreInvalidCertificate
    Accept an untrusted or self-signed certificate on the target endpoint. Use only in lab
    environments.

.PARAMETER DiffOnly
    Show the planned changes and exit without applying any of them. Use this first, every time.

.EXAMPLE
    PS> ./Import-OpsAlertDefinition.ps1 -Server ops2.example.local -Credential $cred -InputPath ./alertdefs.json -DiffOnly

    Shows which alert definitions the target is missing.

.NOTES
    Author        : Sampath
    Product       : Aria Operations (VCF 5.x)
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
    [Parameter()] [string[]]$Name,
    [Parameter()] [int]$PageSize = 500,
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

$expectedSchema     = 'vcf-operations.alert-definition'
$expectedProduct    = 'vcf-operations'
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
    $authBody = @{ username = $Credential.UserName; password = $Credential.GetNetworkCredential().Password } | ConvertTo-Json
    $authResponse = Invoke-RestMethod @restCommon -Method Post -Uri "$baseUri/suite-api/api/auth/token/acquire" -Headers @{ Accept = 'application/json' } -Body $authBody
    $headers = @{ Accept = 'application/json'; Authorization = "vRealizeOpsToken $($authResponse.token)" }
    Write-Verbose "Acquired a VCF Operations API token from $Server"

    $desired = Read-ExportFile -Path $InputPath -ExpectedSchema $expectedSchema `
        -ExpectedProduct $expectedProduct -ExpectedVcfVersion $expectedVcfVersion

    if ($Name) { $desired = @($desired | Where-Object { $_.Name -in $Name }) }

    $current = @()
    $page = 0
    do {
        $uri = '{0}/suite-api/api/alertdefinitions?page={1}&pageSize={2}' -f $baseUri, $page, $PageSize
        $response = Invoke-RestMethod @restCommon -Method Get -Uri $uri -Headers $headers
        foreach ($definition in @($response.alertDefinitions)) {
            $current += [pscustomobject]@{ Name = $definition.name; AdapterKind = $definition.adapterKindKey }
        }
        $page++
    } while (@($response.alertDefinitions).Count -eq $PageSize)

    $symptomIdByName = @{}
    $page = 0
    do {
        $uri = '{0}/suite-api/api/symptomdefinitions?page={1}&pageSize={2}' -f $baseUri, $page, $PageSize
        $response = Invoke-RestMethod @restCommon -Method Get -Uri $uri -Headers $headers
        foreach ($symptom in @($response.symptomDefinitions)) { $symptomIdByName[$symptom.name] = $symptom.id }
        $page++
    } while (@($response.symptomDefinitions).Count -eq $PageSize)

    Write-Verbose ("Input lists {0} definition(s); target has {1} and {2} symptom(s)." -f `
        @($desired).Count, @($current).Count, $symptomIdByName.Count)

    $plan = Compare-DesiredState -Current @($current) -Desired @($desired) `
        -KeyProperty 'Name' -CompareProperty @('AdapterKind')

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
    foreach ($item in ($actionable | Where-Object { $_.Action -eq 'Create' })) {
        $row = $item.Desired

        $symptomIds = @()
        $missing = @()
        foreach ($symptomName in @($row.Symptoms -split '\s*;\s*' | Where-Object { $_ })) {
            if ($symptomIdByName.ContainsKey($symptomName)) { $symptomIds += $symptomIdByName[$symptomName] }
            else { $missing += $symptomName }
        }

        if ($missing) {
            Write-Warning ("'{0}' needs symptom definitions missing from the target: {1}. Skipping." -f $item.Key, ($missing -join ', '))
            [pscustomobject]@{ Definition = $item.Key; Status = 'SkippedMissingSymptom' }
            continue
        }

        if (-not $PSCmdlet.ShouldProcess("alert definition '$($item.Key)'", 'Create')) { continue }

        $payload = @{
            name            = $row.Name
            description     = $row.Description
            adapterKindKey  = $row.AdapterKind
            resourceKindKey = $row.ResourceKind
            waitCycles      = [int]$row.WaitCycles
            cancelCycles    = [int]$row.CancelCycles
            type            = [int]$row.Type
            subType         = [int]$row.SubType
            states          = @(
                @{
                    severity          = (@($row.Criticality -split '\s*;\s*') | Select-Object -First 1)
                    base_symptom_set  = @{ type = 'SYMPTOM_SET'; relation = 'SELF'; aggregation = 'ALL'; symptomDefinitionIds = $symptomIds }
                    impact            = @{ impactType = 'BADGE'; detail = 'health' }
                }
            )
        } | ConvertTo-Json -Depth 12

        try {
            Invoke-RestMethod @restCommon -Method Post -Uri "$baseUri/suite-api/api/alertdefinitions" -Headers $headers -Body $payload | Out-Null
            [pscustomobject]@{ Definition = $item.Key; Status = 'Created' }
        }
        catch {
            Write-Warning ("Could not create '{0}': {1}" -f $item.Key, $_.Exception.Message)
            [pscustomobject]@{ Definition = $item.Key; Status = 'Failed' }
        }
    }
}
finally {
    $headers = $null
}
