<#
.SYNOPSIS
    Exports the NSX tags applied to every virtual machine, one row per VM and tag pair.

.DESCRIPTION
    Reads the fabric VM inventory and flattens the tag list on each one into a row per tag,
    carrying the scope and tag value alongside the VM name and external id.

    NSX tags are the input to dynamic group membership, so they are effectively firewall
    configuration - and they exist nowhere else. Import-NsxVmTag.ps1 replays this file, which is
    how a DR NSX ends up enforcing the same policy as production.

    Pain area addressed: #8 DFW rules and effective membership; #16 Config portability between
    environments.

.PARAMETER Server
    FQDN or IP address of the NSX Manager to connect to.

.PARAMETER Credential
    Credential used to authenticate to NSX Manager.

.PARAMETER Scope
    Limit to tags in these scopes.

.PARAMETER UntaggedOnly
    Return only VMs with no NSX tags at all - the ones dynamic groups will never pick up.

.PARAMETER OutputPath
    Path of the file to write. When omitted the records are only returned on the pipeline and
    nothing is written to disk.

.PARAMETER Format
    Output file format. CSV is the flat table, JSON carries the export envelope that the
    matching import script validates, HTML is a styled table for sharing.

.EXAMPLE
    PS> ./Export-NsxVmTag.ps1 -Server nsx.example.local -Credential $cred -OutputPath ./nsxtags.json -Format JSON

    Captures the whole tag model for replay.

.EXAMPLE
    PS> ./Export-NsxVmTag.ps1 -Server nsx.example.local -Credential $cred -UntaggedOnly

    Finds workloads no dynamic security group will ever match.

.NOTES
    Author        : Sampath
    Product       : NSX-T Data Center (VCF 5.x)
    Target        : VMware Cloud Foundation 5.x
    Modules       : VMware.VimAutomation.Nsxt
    Behaviour     : Read-only. Collects data and optionally writes it to disk.
    Standalone    : Yes. This script does not dot-source or import any other file
                    in this repository and can be copied out on its own.
#>

#Requires -Version 5.1
#Requires -Modules VMware.VimAutomation.Nsxt

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Server,
    [Parameter(Mandatory)] [System.Management.Automation.PSCredential]$Credential,
    [Parameter()] [string[]]$Scope,
    [Parameter()] [switch]$UntaggedOnly,
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
    Schema        = 'nsx.vm-tag'
    SchemaVersion = '1.0'
    Product       = 'nsx'
    VcfVersion    = '5.x'
    Server        = $Server
}

$connection = $null
try {
    $connection = Connect-NsxtServer -Server $Server -Credential $Credential -ErrorAction Stop
    Write-Verbose "Connected to NSX Manager $($connection.Name)"
    # Scope every call in this script to the connection opened above. Without this,
    # PowerCLI cmdlets act on every connected server, which silently mixes inventories
    # when more than one is connected. The hashtable is cloned first because indexing
    # the inherited one would change the caller's session defaults too.
    $PSDefaultParameterValues = $PSDefaultParameterValues.Clone()
    $PSDefaultParameterValues['*:Server'] = $connection

    $records = @()

    $vmService = Get-NsxtService -Name 'com.vmware.nsx.fabric.virtual_machines'
    $virtualMachines = @($vmService.list().results)
    Write-Verbose ("NSX fabric reports {0} virtual machine(s)." -f $virtualMachines.Count)

    foreach ($vm in $virtualMachines) {
        $tags = @($vm.tags)

        if (-not $tags) {
            if ($Scope) { continue }
            $records += [pscustomobject]@{
                VmName     = $vm.display_name
                ExternalId = $vm.external_id
                PowerState = $vm.power_state
                HostId     = $vm.host_id
                Scope      = ''
                Tag        = ''
                TagCount   = 0
            }
            continue
        }

        if ($UntaggedOnly) { continue }

        foreach ($tag in $tags) {
            if ($Scope -and $tag.scope -notin $Scope) { continue }

            $records += [pscustomobject]@{
                VmName     = $vm.display_name
                ExternalId = $vm.external_id
                PowerState = $vm.power_state
                HostId     = $vm.host_id
                Scope      = $tag.scope
                Tag        = $tag.tag
                TagCount   = $tags.Count
            }
        }
    }

    $records = @($records | Sort-Object VmName, Scope, Tag)
    Write-Verbose ("Collected {0} tag row(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    if ($connection) { Disconnect-NsxtServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
