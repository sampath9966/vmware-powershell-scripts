<#
.SYNOPSIS
    Exports every storage policy with its rule set and a count of the VMs and disks currently assigned to it.

.DESCRIPTION
    Captures each SPBM policy - its rule sets flattened into readable capability/value pairs -
    and how many VMs and hard disks are actually using it, so unused policies are obvious and
    the ones that matter are identifiable before a migration.

    Policies are the thing that quietly does not exist in a DR vCenter until a failover tries to
    place an object. Import-VsanStoragePolicy.ps1 replays this file to fix that.

    Pain area addressed: #16 Config portability between environments; #11 vSAN health, capacity,
    policy compliance.

.PARAMETER Server
    FQDN or IP address of the vCenter Server to connect to.

.PARAMETER Credential
    Credential used to authenticate to vCenter Server.

.PARAMETER PolicyName
    Limit to these policy names.

.PARAMETER IncludeSystemPolicy
    Include the built-in system policies.

.PARAMETER OutputPath
    Path of the file to write. When omitted the records are only returned on the pipeline and
    nothing is written to disk.

.PARAMETER Format
    Output file format. CSV is the flat table, JSON carries the export envelope that the
    matching import script validates, HTML is a styled table for sharing.

.EXAMPLE
    PS> ./Export-VsanStoragePolicy.ps1 -Server vcenter.example.local -Credential $cred -OutputPath ./policies.json -Format JSON

    Captures every policy for replay into another vCenter.

.EXAMPLE
    PS> ./Export-VsanStoragePolicy.ps1 -Server vcenter.example.local -Credential $cred | Where-Object UsedByCount -eq 0

    Finds policies nothing is using.

.NOTES
    Author        : Sampath
    Product       : vSAN (ESA and OSA) (VCF 9.x)
    Target        : VMware Cloud Foundation 9.x
    Modules       : VMware.VimAutomation.Core, VMware.VimAutomation.Storage
    Behaviour     : Read-only. Collects data and optionally writes it to disk.
    Standalone    : Yes. This script does not dot-source or import any other file
                    in this repository and can be copied out on its own.
#>

#Requires -Version 5.1
#Requires -Modules VMware.VimAutomation.Core
#Requires -Modules VMware.VimAutomation.Storage

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Server,
    [Parameter(Mandatory)] [System.Management.Automation.PSCredential]$Credential,
    [Parameter()] [string[]]$PolicyName,
    [Parameter()] [switch]$IncludeSystemPolicy,
    [Parameter()] [string]$OutputPath,
    [Parameter()] [ValidateSet('CSV','JSON','HTML')] [string]$Format = 'CSV'
)

$ErrorActionPreference = 'Stop'

function Out-ResultFile {
    <#
        Writes the collected records to disk in the requested format. JSON uses the
        repository's export envelope so a matching Import-*/Invoke-* script can
        validate what it has been handed before changing anything.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowEmptyCollection()][object[]]$Record,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Format,
        [Parameter(Mandatory)][hashtable]$Meta
    )

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    switch ($Format) {
        'CSV' {
            @($Record) | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
        }
        'JSON' {
            [pscustomobject]@{
                schema        = $Meta.Schema
                schemaVersion = $Meta.SchemaVersion
                product       = $Meta.Product
                vcfVersion    = $Meta.VcfVersion
                exportedOn    = (Get-Date).ToUniversalTime().ToString('o')
                sourceServer  = $Meta.Server
                recordCount   = @($Record).Count
                data          = @($Record)
            } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding UTF8
        }
        'HTML' {
            $style = '<style>body{font-family:Segoe UI,Arial,sans-serif;margin:24px}' +
                     'h2{margin-bottom:2px}p.meta{color:#666;margin-top:0;font-size:12px}' +
                     'table{border-collapse:collapse;font-size:13px}' +
                     'th,td{border:1px solid #ccc;padding:4px 8px}th{background:#eee;text-align:left}</style>'
            $header = '<h2>' + $Meta.Schema + '</h2><p class="meta">Source: ' + $Meta.Server +
                      ' | VCF ' + $Meta.VcfVersion + ' | Exported: ' +
                      (Get-Date).ToString('u') + ' | Records: ' + @($Record).Count + '</p>'
            @($Record) | ConvertTo-Html -Head $style -PreContent $header |
                Set-Content -LiteralPath $Path -Encoding UTF8
        }
    }

    Write-Verbose ("Wrote {0} record(s) to {1}" -f @($Record).Count, $Path)
}

$exportMeta = @{
    Schema        = 'vsan.storage-policy'
    SchemaVersion = '1.0'
    Product       = 'vsan'
    VcfVersion    = '9.x'
    Server        = $Server
}

$connection = $null
try {
    $connection = Connect-VIServer -Server $Server -Credential $Credential -ErrorAction Stop
    Write-Verbose "Connected to vCenter Server $($connection.Name) (version $($connection.Version))"

    $records = @()

    $policies = Get-SpbmStoragePolicy -ErrorAction SilentlyContinue
    if ($PolicyName) { $policies = @($policies | Where-Object { $_.Name -in $PolicyName }) }
    Write-Verbose ("Found {0} storage policy/policies." -f @($policies).Count)

    foreach ($policy in $policies) {
        if (-not $IncludeSystemPolicy -and $policy.IsDefault) { continue }

        $rules = @()
        foreach ($ruleSet in @($policy.AnyOfRuleSets)) {
            $parts = @()
            foreach ($rule in @($ruleSet.AllOfRules)) {
                $parts += ('{0}={1}' -f $rule.Capability.Name, $rule.Value)
            }
            $rules += ($parts -join ', ')
        }

        $vmCount = 0
        $diskCount = 0
        try {
            $used = @(Get-SpbmEntityConfiguration -StoragePolicy $policy -ErrorAction SilentlyContinue)
            $vmCount = @($used | Where-Object { $_.Entity -is [VMware.VimAutomation.ViCore.Types.V1.Inventory.VirtualMachine] }).Count
            $diskCount = @($used).Count - $vmCount
        }
        catch { Write-Verbose "Could not count usage for policy '$($policy.Name)'." }

        $records += [pscustomobject]@{
            Name         = $policy.Name
            Id           = $policy.Id
            Description  = $policy.Description
            IsDefault    = $policy.IsDefault
            RuleSets     = ($rules -join ' | ')
            RuleSetCount = @($rules).Count
            UsedByVm     = $vmCount
            UsedByDisk   = $diskCount
            UsedByCount  = $vmCount + $diskCount
        }
    }

    $records = @($records | Sort-Object Name)
    Write-Verbose ("Collected {0} policy record(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    if ($connection) { Disconnect-VIServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
