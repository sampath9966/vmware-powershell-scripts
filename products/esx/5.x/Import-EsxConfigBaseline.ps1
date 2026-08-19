<#
.SYNOPSIS
    Applies NTP, DNS, syslog and service policy from a captured baseline to the hosts that differ.

.DESCRIPTION
    Reads a host configuration export and brings hosts in line with it. Use -BaselineHost to
    take one host in the file as the standard and apply it to everything else, or omit it to
    apply each host's own recorded values back to that host.

    Only the settings you opt into with -Setting are touched. Lockdown mode is deliberately not
    in the default set, because turning it on remotely is how people lock themselves out. Every
    host is a separate ShouldProcess call, so -Confirm walks them one at a time.

    Pain area addressed: #9 Config drift (NTP/DNS/syslog/lockdown).

.PARAMETER Server
    FQDN or IP address of the vCenter Server to connect to.

.PARAMETER Credential
    Credential used to authenticate to vCenter Server.

.PARAMETER InputPath
    Path to the .json (preferred) or .csv file written by the matching Export-* script. The
    envelope is validated before anything is changed.

.PARAMETER BaselineHost
    Take this host's values from the file as the standard and apply them everywhere. Omit to
    replay each host's own values.

.PARAMETER Setting
    Which settings to apply: Ntp, Dns, Syslog, SshPolicy, ShellPolicy. Defaults to Ntp, Dns and
    Syslog.

.PARAMETER Cluster
    Limit the change to hosts in these clusters.

.PARAMETER RestartService
    Restart the NTP service after changing its servers so the change takes effect immediately.

.PARAMETER DiffOnly
    Show the planned changes and exit without applying any of them. Use this first, every time.

.EXAMPLE
    PS> ./Import-EsxConfigBaseline.ps1 -Server vcenter.example.local -Credential $cred -InputPath ./hostconfig.json -BaselineHost esx01.example.local -DiffOnly

    Shows what would change on every host if esx01 became the standard.

.EXAMPLE
    PS> ./Import-EsxConfigBaseline.ps1 -Server vcenter.example.local -Credential $cred -InputPath ./hostconfig.json -BaselineHost esx01.example.local -Setting Ntp -RestartService -Confirm

    Aligns NTP everywhere and restarts the service on each host it changes.

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
    [Parameter()] [string]$BaselineHost,
    [Parameter()] [string[]]$Setting = @('Ntp','Dns','Syslog'),
    [Parameter()] [string[]]$Cluster,
    [Parameter()] [switch]$RestartService,
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

$expectedSchema     = 'esx.host-config'
$expectedProduct    = 'esx'
$expectedVcfVersion = '5.x'

$connection = $null
try {
    $connection = Connect-VIServer -Server $Server -Credential $Credential -ErrorAction Stop
    Write-Verbose "Connected to vCenter Server $($connection.Name) (version $($connection.Version))"

    $desired = Read-ExportFile -Path $InputPath -ExpectedSchema $expectedSchema `
        -ExpectedProduct $expectedProduct -ExpectedVcfVersion $expectedVcfVersion

    $template = $null
    if ($BaselineHost) {
        $template = @($desired | Where-Object { $_.VMHost -eq $BaselineHost })[0]
        if (-not $template) { throw "Host '$BaselineHost' is not present in the input file." }
        Write-Verbose "Using '$BaselineHost' from the file as the baseline for every host."
    }

    $hostFilter = @{}
    if ($Cluster) { $hostFilter['Location'] = Get-Cluster -Name $Cluster }
    $vmHosts = Get-VMHost @hostFilter

    $propertyForSetting = @{
        Ntp         = @('NtpServer')
        Dns         = @('DnsServer', 'SearchDomain')
        Syslog      = @('SyslogHost', 'SyslogLogDir')
        SshPolicy   = @('SshPolicy')
        ShellPolicy = @('ShellPolicy')
    }

    $plan = foreach ($vmHost in $vmHosts) {
        $want = if ($template) { $template } else { @($desired | Where-Object { $_.VMHost -eq $vmHost.Name })[0] }
        if (-not $want) {
            Write-Verbose "No baseline row for '$($vmHost.Name)'. Skipping."
            continue
        }

        $network = Get-VMHostNetwork -VMHost $vmHost -ErrorAction SilentlyContinue
        $services = @(Get-VMHostService -VMHost $vmHost -ErrorAction SilentlyContinue)

        $have = [pscustomobject]@{
            NtpServer    = ((Get-VMHostNtpServer -VMHost $vmHost -ErrorAction SilentlyContinue) -join '; ')
            DnsServer    = if ($network) { ($network.DnsAddress -join '; ') } else { '' }
            SearchDomain = if ($network) { ($network.SearchDomain -join '; ') } else { '' }
            SyslogHost   = (Get-AdvancedSetting -Entity $vmHost -Name 'Syslog.global.logHost' -ErrorAction SilentlyContinue).Value
            SyslogLogDir = (Get-AdvancedSetting -Entity $vmHost -Name 'Syslog.global.logDir' -ErrorAction SilentlyContinue).Value
            SshPolicy    = [string](($services | Where-Object { $_.Key -eq 'TSM-SSH' }).Policy)
            ShellPolicy  = [string](($services | Where-Object { $_.Key -eq 'TSM' }).Policy)
        }

        $changed = @()
        foreach ($group in $Setting) {
            foreach ($property in $propertyForSetting[$group]) {
                if ([string]$have.$property -ne [string]$want.$property) { $changed += $property }
            }
        }

        [pscustomobject]@{
            Key             = $vmHost.Name
            Action          = if ($changed.Count) { 'Update' } else { 'Match' }
            ChangedProperty = ($changed -join ', ')
            VMHost          = $vmHost
            Desired         = $want
            Current         = $have
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
        $want = $item.Desired
        $changed = @($item.ChangedProperty -split ',\s*' | Where-Object { $_ })

        if (-not $PSCmdlet.ShouldProcess($item.Key, "Set $($item.ChangedProperty)")) { continue }

        $applied = @()

        if ($changed -contains 'NtpServer') {
            $existing = @(Get-VMHostNtpServer -VMHost $vmHost -ErrorAction SilentlyContinue)
            if ($existing) { Remove-VMHostNtpServer -VMHost $vmHost -NtpServer $existing -Confirm:$false | Out-Null }
            $wanted = @($want.NtpServer -split '\s*;\s*' | Where-Object { $_ })
            if ($wanted) { Add-VMHostNtpServer -VMHost $vmHost -NtpServer $wanted -Confirm:$false | Out-Null }
            $applied += 'NtpServer'

            if ($RestartService) {
                Get-VMHostService -VMHost $vmHost | Where-Object { $_.Key -eq 'ntpd' } |
                    Restart-VMHostService -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
            }
        }

        if ($changed -contains 'DnsServer' -or $changed -contains 'SearchDomain') {
            $networkParams = @{ VMHost = $vmHost; Confirm = $false }
            if ($changed -contains 'DnsServer') {
                $networkParams['DnsAddress'] = @($want.DnsServer -split '\s*;\s*' | Where-Object { $_ })
            }
            if ($changed -contains 'SearchDomain') {
                $networkParams['SearchDomain'] = @($want.SearchDomain -split '\s*;\s*' | Where-Object { $_ })
            }
            Get-VMHostNetwork -VMHost $vmHost | Set-VMHostNetwork @networkParams | Out-Null
            $applied += 'Dns'
        }

        foreach ($pair in @(@('SyslogHost', 'Syslog.global.logHost'), @('SyslogLogDir', 'Syslog.global.logDir'))) {
            if ($changed -notcontains $pair[0]) { continue }
            Get-AdvancedSetting -Entity $vmHost -Name $pair[1] |
                Set-AdvancedSetting -Value ([string]$want.($pair[0])) -Confirm:$false | Out-Null
            $applied += $pair[0]
        }

        foreach ($pair in @(@('SshPolicy', 'TSM-SSH'), @('ShellPolicy', 'TSM'))) {
            if ($changed -notcontains $pair[0]) { continue }
            Get-VMHostService -VMHost $vmHost | Where-Object { $_.Key -eq $pair[1] } |
                Set-VMHostService -Policy ([string]$want.($pair[0])) -Confirm:$false | Out-Null
            $applied += $pair[0]
        }

        [pscustomobject]@{
            VMHost  = $item.Key
            Applied = ($applied -join ', ')
            Status  = 'Updated'
        }
    }
}
finally {
    if ($connection) { Disconnect-VIServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
