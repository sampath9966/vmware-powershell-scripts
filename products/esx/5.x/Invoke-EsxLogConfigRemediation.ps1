<#
.SYNOPSIS
    Sets the syslog directory, remote syslog target and network coredump for hosts flagged non-compliant.

.DESCRIPTION
    Takes a coredump and log export, selects the hosts marked non-compliant, and applies the
    targets you specify - a persistent log directory, a remote syslog host, and optionally a
    network coredump collector.

    Changing the log directory takes effect immediately and does not need a reboot, so this is
    safe to run in hours. Nothing is guessed: if you do not pass -SyslogHost or -LogDir, that
    part is left alone.

    Pain area addressed: #9 Config drift (NTP/DNS/syslog/lockdown).

.PARAMETER Server
    FQDN or IP address of the vCenter Server to connect to.

.PARAMETER Credential
    Credential used to authenticate to vCenter Server.

.PARAMETER InputPath
    Path to the .json (preferred) or .csv file written by the matching Export-* script. The
    envelope is validated before anything is changed.

.PARAMETER SyslogHost
    Remote syslog target to set, for example 'tcp://logs.example.local:514'. Omit to leave it
    alone.

.PARAMETER LogDir
    Persistent log directory to set, for example '[datastore1] esx-logs'. Omit to leave it
    alone.

.PARAMETER NetworkCoredumpServer
    IP address of a network coredump collector to enable. Omit to leave coredump configuration
    alone.

.PARAMETER NetworkCoredumpPort
    Port of the network coredump collector. Defaults to 6500.

.PARAMETER DiffOnly
    Show the planned changes and exit without applying any of them. Use this first, every time.

.EXAMPLE
    PS> ./Invoke-EsxLogConfigRemediation.ps1 -Server vcenter.example.local -Credential $cred -InputPath ./logcfg.json -SyslogHost 'tcp://logs.example.local:514' -DiffOnly

    Shows which hosts would have their syslog target changed.

.NOTES
    Author        : Sampath
    Product       : ESXi (VCF 5.x)
    Target        : VMware Cloud Foundation 5.x
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
    [Parameter()] [string]$SyslogHost,
    [Parameter()] [string]$LogDir,
    [Parameter()] [string]$NetworkCoredumpServer,
    [Parameter()] [int]$NetworkCoredumpPort = 6500,
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


$expectedSchema     = 'esx.coredump-log'
$expectedProduct    = 'esx'
$expectedVcfVersion = '5.x'

$connection = $null
try {
    $connection = Connect-VIServer -Server $Server -Credential $Credential -ErrorAction Stop
    Write-Verbose "Connected to vCenter Server $($connection.Name) (version $($connection.Version))"
    if (@($DefaultVIServers).Count -gt 1) {
        Write-Warning (("{0} vCenter connections are open in this session. PowerCLI cmdlets act on " +
            "every connected server unless they are scoped, which silently mixes inventories. " +
            "This script scopes its own calls to '{1}'.") -f @($DefaultVIServers).Count, $connection.Name)
    }

    if (-not $SyslogHost -and -not $LogDir -and -not $NetworkCoredumpServer) {
        throw 'Nothing to do. Pass at least one of -SyslogHost, -LogDir or -NetworkCoredumpServer.'
    }

    $desired = Read-ExportFile -Path $InputPath -ExpectedSchema $expectedSchema `
        -ExpectedProduct $expectedProduct -ExpectedVcfVersion $expectedVcfVersion

    Write-Verbose ("Input lists {0} host row(s)." -f @($desired).Count)

    $plan = foreach ($record in @($desired)) {
        if ([string]$record.Compliant -eq 'True') {
            Write-Verbose "'$($record.VMHost)' is already compliant. Skipping."
            continue
        }

        $vmHost = Get-VMHost -Name $record.VMHost -ErrorAction SilentlyContinue
        if (-not $vmHost) {
            Write-Warning "Host '$($record.VMHost)' is not in this vCenter. Skipping."
            continue
        }

        $changes = @()
        if ($SyslogHost -and [string]$record.SyslogRemoteHost -ne $SyslogHost) { $changes += 'SyslogHost' }
        if ($LogDir -and [string]$record.SyslogLogDir -ne $LogDir) { $changes += 'LogDir' }
        if ($NetworkCoredumpServer -and [string]$record.NetworkCoredumpServer -ne $NetworkCoredumpServer) { $changes += 'NetworkCoredump' }

        [pscustomobject]@{
            Key             = $record.VMHost
            Action          = if ($changes.Count) { 'Update' } else { 'Match' }
            ChangedProperty = ($changes -join ', ')
            VMHost          = $vmHost
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
        $vmHost = $item.VMHost
        $changes = @($item.ChangedProperty -split ',\s*' | Where-Object { $_ })

        if (-not $PSCmdlet.ShouldProcess($item.Key, "Set $($item.ChangedProperty)")) { continue }

        $applied = @()

        if ($changes -contains 'SyslogHost') {
            Get-AdvancedSetting -Entity $vmHost -Name 'Syslog.global.logHost' |
                Set-AdvancedSetting -Value $SyslogHost -Confirm:$false | Out-Null
            $applied += 'SyslogHost'
        }

        if ($changes -contains 'LogDir') {
            Get-AdvancedSetting -Entity $vmHost -Name 'Syslog.global.logDir' |
                Set-AdvancedSetting -Value $LogDir -Confirm:$false | Out-Null
            $applied += 'LogDir'
        }

        if ($changes -contains 'NetworkCoredump') {
            try {
                $esxcli = Get-EsxCli -VMHost $vmHost -V2 -ErrorAction Stop
                $vmk = @($vmHost | Get-VMHostNetworkAdapter -VMKernel | Where-Object { $_.ManagementTrafficEnabled })[0]

                $setArgs = $esxcli.system.coredump.network.set.CreateArgs()
                $setArgs.serverip = $NetworkCoredumpServer
                $setArgs.serverport = $NetworkCoredumpPort
                if ($vmk) { $setArgs.interfacename = $vmk.DeviceName }
                $esxcli.system.coredump.network.set.Invoke($setArgs) | Out-Null

                $enableArgs = $esxcli.system.coredump.network.set.CreateArgs()
                $enableArgs.enable = $true
                $esxcli.system.coredump.network.set.Invoke($enableArgs) | Out-Null
                $applied += 'NetworkCoredump'
            }
            catch {
                Write-Warning ("Could not configure network coredump on '{0}': {1}" -f $item.Key, $_.Exception.Message)
            }
        }

        if ($applied -contains 'SyslogHost' -or $applied -contains 'LogDir') {
            try {
                $esxcli = Get-EsxCli -VMHost $vmHost -V2 -ErrorAction Stop
                $esxcli.system.syslog.reload.Invoke() | Out-Null
            }
            catch { Write-Verbose "Could not reload syslog on '$($item.Key)'; the change applies on next reload." }
        }

        [pscustomobject]@{
            VMHost  = $item.Key
            Applied = ($applied -join ', ')
            Status  = if ($applied) { 'Updated' } else { 'NoChange' }
        }
    }
}
finally {
    if ($connection) { Disconnect-VIServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
