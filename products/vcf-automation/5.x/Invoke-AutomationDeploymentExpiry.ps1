<#
.SYNOPSIS
    Sets a short lease on, or destroys, the deployments selected from a reviewed deployment inventory.

.DESCRIPTION
    Takes a deployment inventory export, selects the deployments matching your age and lease
    criteria, and either sets a short lease on them so the owner gets a warning first, or
    destroys them outright.

    Setting a lease is the default and the safe path - it gives the owner notice and lets the
    platform's own expiry process do the deletion. -Action Destroy exists because sometimes the
    owner has left, and it is behind ShouldProcess with a high confirm impact for that reason.
    Always run -DiffOnly first and read the list.

    Pain area addressed: #5 Orphaned and zombie assets; #14 Rightsizing and idle workloads.

.PARAMETER Server
    FQDN or IP address of the VCF Automation appliance.

.PARAMETER Credential
    Credential used to authenticate to the VCF Automation API.

.PARAMETER InputPath
    Path to the .json (preferred) or .csv file written by the matching Export-* script. The
    envelope is validated before anything is changed.

.PARAMETER Action
    What to do: SetLease sets a short lease and warns the owner, Destroy deletes the deployment.
    Defaults to SetLease.

.PARAMETER LeaseDays
    Lease length in days to apply when -Action is SetLease. Defaults to 14.

.PARAMETER IdleSinceDays
    Only act on deployments not updated in this many days. Defaults to 180.

.PARAMETER ExcludeProject
    Projects to leave alone regardless of what the file says.

.PARAMETER IgnoreInvalidCertificate
    Accept an untrusted or self-signed certificate on the target endpoint. Use only in lab
    environments.

.PARAMETER DiffOnly
    Show the planned changes and exit without applying any of them. Use this first, every time.

.EXAMPLE
    PS> ./Invoke-AutomationDeploymentExpiry.ps1 -Server automation.example.local -Credential $cred -InputPath ./deployments.json -DiffOnly

    Lists which deployments would get a short lease. Changes nothing.

.EXAMPLE
    PS> ./Invoke-AutomationDeploymentExpiry.ps1 -Server automation.example.local -Credential $cred -InputPath ./deployments.json -Action Destroy -IdleSinceDays 365 -Confirm

    Destroys deployments untouched for a year, prompting for each.

.NOTES
    Author        : Sampath
    Product       : Aria Automation (VCF 5.x)
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
    [Parameter()] [ValidateSet('SetLease','Destroy')] [string]$Action = 'SetLease',
    [Parameter()] [int]$LeaseDays = 14,
    [Parameter()] [int]$IdleSinceDays = 180,
    [Parameter()] [string[]]$ExcludeProject,
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


$expectedSchema     = 'automation.deployment-inventory'
$expectedProduct    = 'vcf-automation'
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
    $refresh = Invoke-RestMethod @restCommon -Method Post -Uri "$baseUri/csp/gateway/am/api/login?access_token" -Body $authBody
    $exchange = @{ refreshToken = $refresh.refresh_token } | ConvertTo-Json
    $access = Invoke-RestMethod @restCommon -Method Post -Uri "$baseUri/iaas/api/login" -Body $exchange
    $headers = @{ Accept = 'application/json'; Authorization = "Bearer $($access.token)" }
    Write-Verbose "Acquired a VCF Automation access token from $Server"

    $desired = Read-ExportFile -Path $InputPath -ExpectedSchema $expectedSchema `
        -ExpectedProduct $expectedProduct -ExpectedVcfVersion $expectedVcfVersion

    Write-Verbose ("Input lists {0} deployment(s). Action is '{1}'." -f @($desired).Count, $Action)

    $plan = foreach ($record in @($desired)) {
        if ($ExcludeProject -and $record.Project -in $ExcludeProject) { continue }

        $lastUpdated = $null
        if ($record.LastUpdated) {
            try { $lastUpdated = [datetime]$record.LastUpdated } catch { $lastUpdated = $null }
        }

        if (-not $lastUpdated) {
            Write-Verbose "No last-updated date for '$($record.Name)'. Skipping."
            continue
        }

        $idleDays = [int][math]::Floor(((Get-Date) - $lastUpdated).TotalDays)
        if ($idleDays -lt $IdleSinceDays) { continue }

        [pscustomobject]@{
            Key             = $record.Name
            Action          = 'Update'
            ChangedProperty = $Action
            DeploymentId    = $record.DeploymentId
            Project         = $record.Project
            OwnedBy         = $record.OwnedBy
            IdleDays        = $idleDays
            ResourceCount   = $record.ResourceCount
            Desired         = $record
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
    $totalResources = ($actionable | Measure-Object -Property ResourceCount -Sum).Sum
    Write-Verbose ("About to {0} {1} deployment(s) covering roughly {2} resource(s)." -f $Action, $actionable.Count, $totalResources)

    foreach ($item in $actionable) {
        $target = "deployment '{0}' in project '{1}', owned by {2}, idle {3} day(s)" -f `
            $item.Key, $item.Project, $item.OwnedBy, $item.IdleDays

        if (-not $PSCmdlet.ShouldProcess($target, $Action)) { continue }

        try {
            if ($Action -eq 'Destroy') {
                Invoke-RestMethod @restCommon -Method Delete `
                    -Uri ('{0}/deployment/api/deployments/{1}' -f $baseUri, $item.DeploymentId) -Headers $headers | Out-Null
                $status = 'DestroyRequested'
            }
            else {
                $newExpiry = (Get-Date).AddDays($LeaseDays).ToUniversalTime().ToString('o')
                $payload = @{ leaseExpireAt = $newExpiry } | ConvertTo-Json

                Invoke-RestMethod @restCommon -Method Patch `
                    -Uri ('{0}/deployment/api/deployments/{1}' -f $baseUri, $item.DeploymentId) `
                    -Headers $headers -Body $payload | Out-Null
                $status = "LeaseSetTo$LeaseDays" + 'Days'
            }

            [pscustomobject]@{
                Deployment = $item.Key
                Project    = $item.Project
                OwnedBy    = $item.OwnedBy
                IdleDays   = $item.IdleDays
                Status     = $status
            }
        }
        catch {
            Write-Warning ("Could not {0} '{1}': {2}" -f $Action, $item.Key, $_.Exception.Message)
            [pscustomobject]@{ Deployment = $item.Key; Project = $item.Project; OwnedBy = $item.OwnedBy; IdleDays = $item.IdleDays; Status = 'Failed' }
        }
    }
}
finally {
    $headers = $null
}
