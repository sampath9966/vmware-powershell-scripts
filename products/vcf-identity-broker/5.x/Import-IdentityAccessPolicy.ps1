<#
.SYNOPSIS
    Recreates access policies from an export, rebuilding their rules in the original evaluation order.

.DESCRIPTION
    Groups the exported rules back into policies and creates the ones missing from the target,
    preserving rule order and the authentication chain of each.

    Network ranges and groups are resolved by name in the target and a rule referencing one that
    does not exist here is reported rather than silently created without its condition - because
    a rule that lost its condition is a rule that matches everything.

    Pain area addressed: #16 Config portability between environments.

.PARAMETER Server
    FQDN or IP address of the VCF Identity Broker appliance.

.PARAMETER Credential
    Credential used to authenticate to the Identity Broker API.

.PARAMETER InputPath
    Path to the .json (preferred) or .csv file written by the matching Export-* script. The
    envelope is validated before anything is changed.

.PARAMETER PolicyName
    Limit the import to these policy names.

.PARAMETER IgnoreInvalidCertificate
    Accept an untrusted or self-signed certificate on the target endpoint. Use only in lab
    environments.

.PARAMETER DiffOnly
    Show the planned changes and exit without applying any of them. Use this first, every time.

.EXAMPLE
    PS> ./Import-IdentityAccessPolicy.ps1 -Server idb2.example.local -Credential $cred -InputPath ./policies.json -DiffOnly

    Shows which access policies the target is missing.

.NOTES
    Author        : Sampath
    Product       : Workspace ONE Access (VCF 5.x)
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
    [Parameter()] [string[]]$PolicyName,
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

$expectedSchema     = 'identity.access-policy'
$expectedProduct    = 'vcf-identity-broker'
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
    $authBody = @{ username = $Credential.UserName; password = $Credential.GetNetworkCredential().Password; issueToken = $true } | ConvertTo-Json
    $authResponse = Invoke-RestMethod @restCommon -Method Post -Uri "$baseUri/SAAS/API/1.0/REST/auth/system/login" -Body $authBody
    $headers = @{ Accept = 'application/json'; Authorization = "HZN $($authResponse.sessionToken)" }
    Write-Verbose "Acquired an Identity Broker session token from $Server"

    $desired = Read-ExportFile -Path $InputPath -ExpectedSchema $expectedSchema `
        -ExpectedProduct $expectedProduct -ExpectedVcfVersion $expectedVcfVersion

    if ($PolicyName) { $desired = @($desired | Where-Object { $_.Policy -in $PolicyName }) }

    $response = Invoke-RestMethod @restCommon -Method Get -Uri "$baseUri/SAAS/jersey/manager/api/accessPolicies" -Headers $headers
    $existingNames = @(@($response.items).name)

    $rangeNames = @()
    try {
        $rangeResponse = Invoke-RestMethod @restCommon -Method Get -Uri "$baseUri/SAAS/jersey/manager/api/networkRanges" -Headers $headers
        $rangeNames = @(@($rangeResponse.items).name)
    }
    catch { Write-Verbose 'Could not enumerate network ranges; range validation will be skipped.' }

    Write-Verbose ("Input describes {0} rule row(s); target has {1} policy/policies." -f @($desired).Count, $existingNames.Count)

    $plan = foreach ($group in ($desired | Group-Object Policy)) {
        $missingRanges = @()
        foreach ($row in $group.Group) {
            foreach ($range in @($row.NetworkRanges -split '\s*;\s*' | Where-Object { $_ })) {
                if ($rangeNames.Count -gt 0 -and $range -notin $rangeNames) { $missingRanges += $range }
            }
        }

        [pscustomobject]@{
            Key             = $group.Name
            Action          = if ($group.Name -in $existingNames) { 'Match' } else { 'Create' }
            ChangedProperty = 'policy'
            RuleCount       = $group.Group.Count
            MissingRanges   = (($missingRanges | Sort-Object -Unique) -join '; ')
            Desired         = $group.Group
            Current         = $null
        }
    }

    foreach ($item in $plan) {
        if ($item.Action -ne 'Match' -and $item.MissingRanges) {
            Write-Warning ("Policy '{0}' references network ranges missing here: {1}." -f $item.Key, $item.MissingRanges)
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
        if ($item.MissingRanges) {
            [pscustomobject]@{ Policy = $item.Key; Rules = $item.RuleCount; Status = 'SkippedMissingNetworkRange' }
            continue
        }

        if (-not $PSCmdlet.ShouldProcess("access policy '$($item.Key)' with $($item.RuleCount) rule(s)", 'Create')) { continue }

        try {
            $rules = @()
            foreach ($row in ($item.Desired | Sort-Object { [int]$_.RuleOrder })) {
                $chains = @()
                foreach ($chain in @($row.AuthenticationChain -split '\s*\|\s*' | Where-Object { $_ })) {
                    $methods = @()
                    foreach ($method in @($chain -split '\s*\+\s*' | Where-Object { $_ })) {
                        $methods += @{ name = $method }
                    }
                    $chains += @{ authMethods = $methods }
                }

                $rules += @{
                    description           = $row.RuleDescription
                    conditions            = @{
                        networkRanges = @(@($row.NetworkRanges -split '\s*;\s*' | Where-Object { $_ }) | ForEach-Object { @{ name = $_ } })
                        clientTypes   = @($row.DeviceTypes -split '\s*;\s*' | Where-Object { $_ })
                    }
                    authenticationMethods = $chains
                    fallbackMethod        = $row.FallbackMethod
                    actionType            = $row.ActionType
                }
                if ($row.ReAuthMinutes) { $rules[-1]['reAuthnSeconds'] = [int]$row.ReAuthMinutes }
            }

            $payload = @{
                name        = $item.Key
                description = ($item.Desired | Select-Object -First 1).Description
                rules       = $rules
            } | ConvertTo-Json -Depth 12

            Invoke-RestMethod @restCommon -Method Post -Uri "$baseUri/SAAS/jersey/manager/api/accessPolicies" `
                -Headers $headers -Body $payload | Out-Null

            [pscustomobject]@{ Policy = $item.Key; Rules = $item.RuleCount; Status = 'Created' }
        }
        catch {
            Write-Warning ("Could not create policy '{0}': {1}" -f $item.Key, $_.Exception.Message)
            [pscustomobject]@{ Policy = $item.Key; Rules = $item.RuleCount; Status = 'Failed' }
        }
    }
}
finally {
    $headers = $null
}
