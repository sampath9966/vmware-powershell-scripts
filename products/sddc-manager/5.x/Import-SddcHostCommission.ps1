<#
.SYNOPSIS
    Commissions the hosts described in a commission spec, skipping any that SDDC Manager already knows.

.DESCRIPTION
    Reads a host commission spec, compares it against the hosts already commissioned, and
    commissions only the ones that are missing. Hosts already present come back marked Match and
    are left alone, so the script is safe to re-run after a partial failure.

    Host passwords are not read from the file unless they are present in it. Supply
    -HostCredential to use one credential for every host in the run, which is the usual case for
    a freshly imaged rack.

    Calls GET /v1/hosts then POST /v1/hosts, and polls GET /v1/tasks/{id}.

    Pain area addressed: #10 Cross-domain inventory; #16 Config portability between
    environments.

.PARAMETER Server
    FQDN or IP address of the SDDC Manager appliance.

.PARAMETER Credential
    Credential used to authenticate to SDDC Manager (for example administrator@vsphere.local).

.PARAMETER InputPath
    Path to the .json (preferred) or .csv file written by the matching Export-* script. The
    envelope is validated before anything is changed.

.PARAMETER HostCredential
    Credential to use for every host being commissioned. Overrides any password present in the
    input file.

.PARAMETER TimeoutMinutes
    How long to wait for the commission task to settle. Defaults to 60.

.PARAMETER IgnoreInvalidCertificate
    Accept an untrusted or self-signed certificate on the SDDC Manager endpoint. Use only in lab
    environments.

.PARAMETER DiffOnly
    Show the planned changes and exit without applying any of them. Use this first, every time.

.EXAMPLE
    PS> ./Import-SddcHostCommission.ps1 -Server sddc.example.local -Credential $cred -InputPath ./hosts.json -DiffOnly

    Shows which hosts in the file are missing from the instance. Commissions nothing.

.EXAMPLE
    PS> ./Import-SddcHostCommission.ps1 -Server sddc.example.local -Credential $cred -InputPath ./hosts.json -HostCredential $rootCred -Confirm

    Commissions the missing hosts using one root credential for all of them.

.NOTES
    Author        : Sampath
    Product       : SDDC Manager (VCF 5.x)
    Target        : VMware Cloud Foundation 5.x
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
    [Parameter()] [System.Management.Automation.PSCredential]$HostCredential,
    [Parameter()] [int]$TimeoutMinutes = 60,
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

$expectedSchema     = 'vcf.sddc.host-commission-spec'
$expectedProduct    = 'sddc-manager'
$expectedVcfVersion = '5.x'

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

    $current = foreach ($vmHost in @((Invoke-VcfGetHosts).Elements)) {
        [pscustomobject]@{
            HostFqdn        = $vmHost.Fqdn
            NetworkPoolName = $vmHost.NetworkPool.Name
            StorageType     = $vmHost.StorageType
        }
    }

    Write-Verbose ("Input lists {0} host(s); the instance already has {1}." -f @($desired).Count, @($current).Count)

    $plan = Compare-DesiredState -Current @($current) -Desired @($desired) `
        -KeyProperty 'HostFqdn' -CompareProperty @('NetworkPoolName', 'StorageType')

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
    $creates = @($actionable | Where-Object { $_.Action -eq 'Create' })
    if (@($actionable).Count -ne $creates.Count) {
        Write-Warning 'Hosts already commissioned cannot be re-commissioned in place; only new hosts will be added.'
    }

    foreach ($item in $creates) {
        $record = $item.Desired
        $target = "host {0} into network pool {1}" -f $record.HostFqdn, $record.NetworkPoolName

        if (-not $PSCmdlet.ShouldProcess($target, 'Commission host')) {
            continue
        }

        $password = if ($HostCredential) { $HostCredential.GetNetworkCredential().Password } else { $record.HostPassword }
        $username = if ($HostCredential) { $HostCredential.UserName } else { $record.Username }

        if (-not $password) {
            Write-Warning "No password available for $($record.HostFqdn). Supply -HostCredential. Skipping."
            continue
        }

        $spec = Initialize-VcfHostCommissionSpec -Fqdn $record.HostFqdn `
            -Username $username -Password $password `
            -NetworkPoolName $record.NetworkPoolName -StorageType $record.StorageType

        $task = Invoke-VcfCommissionHosts -HostCommissionSpec @($spec)

        $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
        while ((Get-Date) -lt $deadline) {
            $task = Invoke-VcfGetTask -Id $task.Id
            if ($task.Status -in @('SUCCESSFUL', 'FAILED', 'CANCELLED')) { break }
            Start-Sleep -Seconds 20
        }

        [pscustomobject]@{
            HostFqdn = $record.HostFqdn
            TaskId   = $task.Id
            Status   = $task.Status
            Message  = $task.Errors.Message -join '; '
        }
    }
}
finally {
    if ($connection) { Disconnect-VcfSddcManagerServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
