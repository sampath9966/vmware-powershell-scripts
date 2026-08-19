<#
.SYNOPSIS
    Re-applies the assigned storage policy to VMs and disks reported as non-compliant, in throttled batches.

.DESCRIPTION
    Takes a compliance export, re-checks each object is still non-compliant, and re-applies its
    assigned policy so vSAN rebuilds the object to spec. Objects that have since come back into
    compliance are skipped.

    Re-applying a policy generates resync traffic, so this is throttled: -MaxConcurrent limits
    how many objects are in flight and the script waits for the cluster resync queue to drop
    below -ResyncThresholdGB before starting each batch. Run it in a quiet window.

    Pain area addressed: #11 vSAN health, capacity, policy compliance.

.PARAMETER Server
    FQDN or IP address of the vCenter Server to connect to.

.PARAMETER Credential
    Credential used to authenticate to vCenter Server.

.PARAMETER InputPath
    Path to the .json (preferred) or .csv file written by the matching Export-* script. The
    envelope is validated before anything is changed.

.PARAMETER MaxConcurrent
    How many objects to re-apply before waiting for resync to settle. Defaults to 5.

.PARAMETER ResyncThresholdGB
    Wait until the cluster has less than this much left to resync before starting the next
    batch. Defaults to 50.

.PARAMETER WaitTimeoutMinutes
    How long to wait for resync to fall below the threshold. Defaults to 120.

.PARAMETER DiffOnly
    Show the planned changes and exit without applying any of them. Use this first, every time.

.EXAMPLE
    PS> ./Invoke-VsanPolicyReapply.ps1 -Server vcenter.example.local -Credential $cred -InputPath ./compliance.json -DiffOnly

    Lists the objects that would be rebuilt. Changes nothing.

.NOTES
    Author        : Sampath
    Product       : vSAN (ESA and OSA) (VCF 9.x)
    Target        : VMware Cloud Foundation 9.x
    Modules       : VMware.VimAutomation.Core, VMware.VimAutomation.Storage
    Behaviour     : Changes the target. Supports -WhatIf, -Confirm and -DiffOnly.
    Standalone    : Yes. This script does not dot-source or import any other file
                    in this repository and can be copied out on its own.
#>

#Requires -Version 5.1
#Requires -Modules VMware.VimAutomation.Core
#Requires -Modules VMware.VimAutomation.Storage

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Server,
    [Parameter(Mandatory)] [System.Management.Automation.PSCredential]$Credential,
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$InputPath,
    [Parameter()] [int]$MaxConcurrent = 5,
    [Parameter()] [double]$ResyncThresholdGB = 50,
    [Parameter()] [int]$WaitTimeoutMinutes = 120,
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


$expectedSchema     = 'vsan.object-compliance'
$expectedProduct    = 'vsan'
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

    $desired = @($desired | Where-Object { $_.Kind -in @('Object', 'Disk') })
    Write-Verbose ("Input lists {0} object row(s)." -f @($desired).Count)

    $batch = 0
    $counter = 0
    $plan = foreach ($record in @($desired)) {
        $vm = Get-VM -Name $record.VM -ErrorAction SilentlyContinue
        if (-not $vm) {
            Write-Warning "VM '$($record.VM)' is not in this vCenter. Skipping."
            continue
        }

        $live = if ($record.Kind -eq 'Disk') {
            $disk = Get-HardDisk -VM $vm -Name $record.Entity -ErrorAction SilentlyContinue
            if ($disk) { Get-SpbmEntityConfiguration -HardDisk $disk -ErrorAction SilentlyContinue } else { $null }
        }
        else {
            Get-SpbmEntityConfiguration -VM $vm -ErrorAction SilentlyContinue
        }

        if (-not $live) { continue }
        if ([string]$live.ComplianceStatus -eq 'compliant') {
            Write-Verbose "'$($record.VM)/$($record.Entity)' is compliant again. Skipping."
            continue
        }

        if ($counter % $MaxConcurrent -eq 0) { $batch++ }
        $counter++

        [pscustomobject]@{
            Key             = '{0}/{1}' -f $record.VM, $record.Entity
            Action          = 'Update'
            ChangedProperty = 'compliance'
            Batch           = $batch
            Cluster         = $record.Cluster
            VM              = $record.VM
            Entity          = $record.Entity
            StoragePolicy   = [string]$live.StoragePolicy
            Desired         = $record
            Current         = $live
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
    foreach ($group in ($actionable | Group-Object -Property Batch)) {
        $clusterNames = @($group.Group.Cluster | Sort-Object -Unique)

        foreach ($clusterName in $clusterNames) {
            $vsanCluster = Get-Cluster -Name $clusterName -ErrorAction SilentlyContinue
            if (-not $vsanCluster) { continue }

            $deadline = (Get-Date).AddMinutes($WaitTimeoutMinutes)
            while ((Get-Date) -lt $deadline) {
                $resync = @(Get-VsanResyncingComponent -Cluster $vsanCluster -ErrorAction SilentlyContinue)
                $pendingGb = if ($resync) { [math]::Round((($resync | Measure-Object -Property BytesToSync -Sum).Sum) / 1GB, 2) } else { 0 }
                if ($pendingGb -lt $ResyncThresholdGB) { break }
                Write-Verbose ("Cluster '{0}' still has {1} GB to resync. Waiting." -f $clusterName, $pendingGb)
                Start-Sleep -Seconds 60
            }
        }

        foreach ($item in $group.Group) {
            if (-not $PSCmdlet.ShouldProcess($item.Key, "Re-apply policy '$($item.StoragePolicy)'")) { continue }

            $status = 'Reapplied'
            $message = ''
            try {
                Set-SpbmEntityConfiguration -Configuration $item.Current `
                    -StoragePolicy $item.StoragePolicy -Confirm:$false -ErrorAction Stop | Out-Null
            }
            catch {
                $status = 'Failed'
                $message = $_.Exception.Message
                Write-Warning ("Could not re-apply policy on {0}: {1}" -f $item.Key, $message)
            }

            [pscustomobject]@{
                Object        = $item.Key
                Cluster       = $item.Cluster
                StoragePolicy = $item.StoragePolicy
                Batch         = $item.Batch
                Status        = $status
                Message       = $message
            }
        }
    }
}
finally {
    if ($connection) { Disconnect-VIServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
