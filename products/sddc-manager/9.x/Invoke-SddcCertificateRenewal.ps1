<#
.SYNOPSIS
    Renews SDDC Manager managed certificates for the resources listed in a certificate inventory export.

.DESCRIPTION
    Takes the file produced by Export-SddcCertificateInventory.ps1, works out which of those
    resources are inside the -ExpiringInDays window, and asks SDDC Manager to reissue their
    certificates from the configured certificate authority.

    The plan is printed before anything happens and every single replacement is gated behind
    ShouldProcess, so -DiffOnly and -WhatIf both give you the full list of what would change
    without touching the environment. Certificate replacement restarts services on the target
    component - run it in a maintenance window.

    Calls POST /v1/domains/{id}/certificates with an operation of INSTALL, then polls GET
    /v1/tasks/{id} until the task settles.

    Pain area addressed: #1 Certificate expiry across the stack.

.PARAMETER Server
    FQDN or IP address of the SDDC Manager appliance.

.PARAMETER Credential
    Credential used to authenticate to SDDC Manager (for example administrator@vsphere.local).

.PARAMETER InputPath
    Path to the .json (preferred) or .csv file written by the matching Export-* script. The
    envelope is validated before anything is changed.

.PARAMETER ExpiringInDays
    Only renew certificates expiring within this many days. Defaults to 30.

.PARAMETER ResourceType
    Limit renewal to these resource types, for example VCENTER or NSXT. Omit to include every
    type in the file.

.PARAMETER TimeoutMinutes
    How long to wait for each renewal task to reach a terminal state before giving up on the
    wait. Defaults to 30.

.PARAMETER IgnoreInvalidCertificate
    Accept an untrusted or self-signed certificate on the SDDC Manager endpoint. Use only in lab
    environments.

.PARAMETER DiffOnly
    Show the planned changes and exit without applying any of them. Use this first, every time.

.EXAMPLE
    PS> ./Invoke-SddcCertificateRenewal.ps1 -Server sddc.example.local -Credential $cred -InputPath ./certs.json -DiffOnly

    Shows exactly which certificates would be reissued and stops. Always start here.

.EXAMPLE
    PS> ./Invoke-SddcCertificateRenewal.ps1 -Server sddc.example.local -Credential $cred -InputPath ./certs.json -ExpiringInDays 14 -Confirm

    Reissues only the certificates inside 14 days, prompting per resource.

.NOTES
    Author        : Sampath
    Product       : SDDC Manager (VCF 9.x)
    Target        : VMware Cloud Foundation 9.x
    Modules       : VMware.Sdk.Vcf.SddcManager
    Behaviour     : Changes the target. Supports -WhatIf, -Confirm and -DiffOnly.
    Standalone    : Yes. This script does not dot-source or import any other file
                    in this repository and can be copied out on its own.
#>

#Requires -Version 5.1
#Requires -Modules VMware.Sdk.Vcf.SddcManager

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Server,
    [Parameter(Mandatory)] [System.Management.Automation.PSCredential]$Credential,
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$InputPath,
    [Parameter()] [int]$ExpiringInDays = 30,
    [Parameter()] [string[]]$ResourceType,
    [Parameter()] [int]$TimeoutMinutes = 30,
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


$expectedSchema     = 'vcf.sddc.certificate-inventory'
$expectedProduct    = 'sddc-manager'
$expectedVcfVersion = '9.x'

$connection = $null
try {
    $connectParams = @{
        Server   = $Server
        User     = $Credential.UserName
        Password = $Credential.GetNetworkCredential().Password
    }
    if ($IgnoreInvalidCertificate) { $connectParams['IgnoreInvalidCertificate'] = $true }
    $connection = Connect-VcfSddcManagerServer @connectParams -ErrorAction Stop
    Write-Verbose "Connected to SDDC Manager $Server"
    # Scope every call in this script to the connection opened above. Without this,
    # PowerCLI cmdlets act on every connected server, which silently mixes inventories
    # when more than one is connected. The hashtable is cloned first because indexing
    # the inherited one would change the caller's session defaults too.
    $PSDefaultParameterValues = $PSDefaultParameterValues.Clone()
    $PSDefaultParameterValues['*:Server'] = $connection

    $desired = Read-ExportFile -Path $InputPath -ExpectedSchema $expectedSchema `
        -ExpectedProduct $expectedProduct -ExpectedVcfVersion $expectedVcfVersion

    Write-Verbose ("Input file lists {0} certificate record(s)." -f @($desired).Count)

    $plan = foreach ($record in @($desired)) {
        if ($ResourceType -and $record.ResourceType -notin $ResourceType) { continue }

        $days = $null
        if ($null -ne $record.DaysRemaining -and $record.DaysRemaining -ne '') {
            $days = [int]$record.DaysRemaining
        }

        $action = if ($null -eq $days) { 'Match' }
                  elseif ($days -le $ExpiringInDays) { 'Update' }
                  else { 'Match' }

        [pscustomobject]@{
            Key             = $record.ResourceFqdn
            Action          = $action
            ChangedProperty = if ($action -eq 'Update') { 'certificate' } else { '' }
            Domain          = $record.Domain
            DomainId        = $record.DomainId
            ResourceType    = $record.ResourceType
            DaysRemaining   = $days
            Desired         = $record
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
    foreach ($item in $actionable) {
        $target = "{0} ({1}) in domain {2}" -f $item.Key, $item.ResourceType, $item.Domain

        if (-not $PSCmdlet.ShouldProcess($target, 'Reissue and install certificate')) {
            continue
        }

        Write-Verbose "Requesting certificate reissue for $target."

        $resource = Initialize-VcfResource -Fqdn $item.Key -ResourceType $item.ResourceType
        $spec = Initialize-VcfCertificatesUpdateSpec -OperationType 'INSTALL' -Resources @($resource)

        $task = Invoke-VcfUpdateCertificates -Id $item.DomainId -CertificatesUpdateSpec $spec

        $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
        while ((Get-Date) -lt $deadline) {
            $task = Invoke-VcfGetTask -Id $task.Id
            if ($task.Status -in @('SUCCESSFUL', 'FAILED', 'CANCELLED')) { break }
            Start-Sleep -Seconds 15
        }

        [pscustomobject]@{
            ResourceFqdn = $item.Key
            ResourceType = $item.ResourceType
            Domain       = $item.Domain
            TaskId       = $task.Id
            Status       = $task.Status
            Message      = $task.Errors.Message -join '; '
        }
    }
}
finally {
    if ($connection) { Disconnect-VcfSddcManagerServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
