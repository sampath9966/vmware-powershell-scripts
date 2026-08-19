<#
.SYNOPSIS
    Sets advanced settings on hosts whose current value differs from a captured baseline.

.DESCRIPTION
    Reads an advanced settings export and, for each host and setting pair, compares it to what
    the host has now. Only differences are changed. Use -BaselineHost to promote one host's
    values to the standard for all of them.

    Advanced settings can make a host unbootable if set wrongly, so nothing is applied without
    an explicit -Name filter or -AllSettings, and every host and setting pair is a separate
    ShouldProcess call. Some settings only take effect after a reboot; that is called out in the
    result rather than acted on.

    Pain area addressed: #9 Config drift (NTP/DNS/syslog/lockdown).

.PARAMETER Server
    FQDN or IP address of the vCenter Server to connect to.

.PARAMETER Credential
    Credential used to authenticate to vCenter Server.

.PARAMETER InputPath
    Path to the .json (preferred) or .csv file written by the matching Export-* script. The
    envelope is validated before anything is changed.

.PARAMETER BaselineHost
    Take this host's values from the file as the standard for every host.

.PARAMETER Name
    Only apply these setting names. Wildcards accepted.

.PARAMETER AllSettings
    Apply every setting in the file. Required if -Name is not given.

.PARAMETER Cluster
    Limit the change to hosts in these clusters.

.PARAMETER DiffOnly
    Show the planned changes and exit without applying any of them. Use this first, every time.

.EXAMPLE
    PS> ./Import-EsxAdvancedSetting.ps1 -Server vcenter.example.local -Credential $cred -InputPath ./adv.json -Name 'Syslog.*' -DiffOnly

    Shows which hosts have syslog settings that differ from the baseline.

.NOTES
    Author        : Sampath
    Product       : ESX (VCF 9.x)
    Target        : VMware Cloud Foundation 9.x
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
    [Parameter()] [string[]]$Name,
    [Parameter()] [switch]$AllSettings,
    [Parameter()] [string[]]$Cluster,
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

$expectedSchema     = 'esx.advanced-setting'
$expectedProduct    = 'esx'
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

    if (-not $Name -and -not $AllSettings) {
        throw 'Refusing to apply every advanced setting implicitly. Pass -Name with the settings you mean, or -AllSettings.'
    }

    $desired = Read-ExportFile -Path $InputPath -ExpectedSchema $expectedSchema `
        -ExpectedProduct $expectedProduct -ExpectedVcfVersion $expectedVcfVersion

    if ($Name) {
        $desired = @($desired | Where-Object {
            $row = $_
            @($Name | Where-Object { $row.Name -like $_ }).Count -gt 0
        })
    }

    $hostFilter = @{}
    if ($Cluster) { $hostFilter['Location'] = Get-Cluster -Name $Cluster }
    $vmHosts = Get-VMHost @hostFilter
    Write-Verbose ("Comparing {0} desired setting row(s) against {1} host(s)." -f @($desired).Count, @($vmHosts).Count)

    $baselineRows = $null
    if ($BaselineHost) {
        $baselineRows = @($desired | Where-Object { $_.VMHost -eq $BaselineHost })
        if (-not $baselineRows) { throw "Host '$BaselineHost' is not present in the input file." }
    }

    $plan = foreach ($vmHost in $vmHosts) {
        $rows = if ($baselineRows) { $baselineRows } else { @($desired | Where-Object { $_.VMHost -eq $vmHost.Name }) }

        foreach ($row in $rows) {
            $live = Get-AdvancedSetting -Entity $vmHost -Name $row.Name -ErrorAction SilentlyContinue
            if (-not $live) {
                Write-Verbose "Setting '$($row.Name)' does not exist on '$($vmHost.Name)'. Skipping."
                continue
            }

            $action = if ([string]$live.Value -eq [string]$row.Value) { 'Match' } else { 'Update' }

            [pscustomobject]@{
                Key             = '{0}|{1}' -f $vmHost.Name, $row.Name
                Action          = $action
                ChangedProperty = if ($action -eq 'Update') { 'Value' } else { '' }
                VMHost          = $vmHost.Name
                Name            = $row.Name
                CurrentValue    = [string]$live.Value
                DesiredValue    = [string]$row.Value
                Desired         = $row
                Current         = $live
            }
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
        $target = "{0} on {1}: '{2}' -> '{3}'" -f $item.Name, $item.VMHost, $item.CurrentValue, $item.DesiredValue

        if (-not $PSCmdlet.ShouldProcess($target, 'Set advanced setting')) { continue }

        $status = 'Updated'
        $message = ''
        try {
            Set-AdvancedSetting -AdvancedSetting $item.Current -Value $item.DesiredValue -Confirm:$false -ErrorAction Stop | Out-Null
        }
        catch {
            $status = 'Failed'
            $message = $_.Exception.Message
            Write-Warning ("Could not set {0}: {1}" -f $target, $message)
        }

        [pscustomobject]@{
            VMHost   = $item.VMHost
            Name     = $item.Name
            OldValue = $item.CurrentValue
            NewValue = $item.DesiredValue
            Status   = $status
            Message  = $message
        }
    }
}
finally {
    if ($connection) { Disconnect-VIServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
