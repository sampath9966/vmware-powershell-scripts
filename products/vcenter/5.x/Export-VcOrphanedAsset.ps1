<#
.SYNOPSIS
    Finds orphaned and inaccessible VMs, registered-nowhere VMDK files, and templates nobody has touched in months.

.DESCRIPTION
    Three separate hunts in one pass. First, VMs whose connection state is orphaned or
    inaccessible. Second, the expensive one - every .vmdk on every accessible datastore,
    compared against the disk backings actually registered to a VM, so the leftovers surface.
    Third, templates whose last modification is older than the age you set.

    Zombie VMDKs are the classic silent capacity leak: a VM is removed from inventory instead of
    deleted from disk, and the files sit there for years. Nothing in the UI looks for them. The
    datastore browse is slow, so it is opt-in behind -IncludeZombieDisk.

    Pain area addressed: #5 Orphaned and zombie assets.

.PARAMETER Server
    FQDN or IP address of the vCenter Server to connect to.

.PARAMETER Credential
    Credential used to authenticate to vCenter Server.

.PARAMETER IncludeZombieDisk
    Browse every accessible datastore for .vmdk files that no registered VM references. Slow on
    large estates.

.PARAMETER StaleTemplateDays
    Report templates not modified in this many days. Defaults to 365. Set 0 to skip the template
    check.

.PARAMETER Datastore
    Limit the zombie disk search to these datastores.

.PARAMETER OutputPath
    Path of the file to write. When omitted the records are only returned on the pipeline and
    nothing is written to disk.

.PARAMETER Format
    Output file format. CSV is the flat table, JSON carries the export envelope that the
    matching import script validates, HTML is a styled table for sharing.

.EXAMPLE
    PS> ./Export-VcOrphanedAsset.ps1 -Server vcenter.example.local -Credential $cred -IncludeZombieDisk -OutputPath ./orphans.json -Format JSON

    Runs the full hunt and writes a file Invoke-VcOrphanedAssetCleanup.ps1 can act on.

.EXAMPLE
    PS> ./Export-VcOrphanedAsset.ps1 -Server vcenter.example.local -Credential $cred | Group-Object Finding

    Summarises what was found by category.

.NOTES
    Author        : Sampath
    Product       : vCenter Server (VCF 5.x)
    Target        : VMware Cloud Foundation 5.x
    Modules       : VMware.VimAutomation.Core
    Behaviour     : Read-only. Collects data and optionally writes it to disk.
    Standalone    : Yes. This script does not dot-source or import any other file
                    in this repository and can be copied out on its own.
#>

#Requires -Version 5.1
#Requires -Modules VMware.VimAutomation.Core

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Server,
    [Parameter(Mandatory)] [System.Management.Automation.PSCredential]$Credential,
    [Parameter()] [switch]$IncludeZombieDisk,
    [Parameter()] [int]$StaleTemplateDays = 365,
    [Parameter()] [string[]]$Datastore,
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
    Schema        = 'vcenter.orphaned-asset'
    SchemaVersion = '1.0'
    Product       = 'vcenter'
    VcfVersion    = '5.x'
    Server        = $Server
}

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

    $records = @()

    foreach ($vm in (Get-VM)) {
        $state = [string]$vm.ExtensionData.Runtime.ConnectionState
        if ($state -in @('orphaned', 'inaccessible', 'invalid')) {
            $records += [pscustomobject]@{
                Finding      = 'OrphanedVM'
                Name         = $vm.Name
                Path         = $vm.ExtensionData.Config.Files.VmPathName
                Datastore    = ''
                SizeGB       = [math]::Round($vm.UsedSpaceGB, 2)
                LastModified = $null
                Detail       = "Connection state is '$state'."
                ObjectId     = $vm.Id
            }
        }
    }

    if ($StaleTemplateDays -gt 0) {
        $cutoff = (Get-Date).AddDays(-$StaleTemplateDays)
        foreach ($template in (Get-Template -ErrorAction SilentlyContinue)) {
            $changed = $template.ExtensionData.Config.Modified
            if ($changed -and $changed -lt $cutoff) {
                $records += [pscustomobject]@{
                    Finding      = 'StaleTemplate'
                    Name         = $template.Name
                    Path         = $template.ExtensionData.Config.Files.VmPathName
                    Datastore    = ''
                    SizeGB       = $null
                    LastModified = $changed
                    Detail       = ("Not modified in {0} day(s)." -f [int]((Get-Date) - $changed).TotalDays)
                    ObjectId     = $template.Id
                }
            }
        }
    }

    if ($IncludeZombieDisk) {
        Write-Verbose 'Building the list of VMDK files referenced by registered VMs.'
        $registered = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($disk in (Get-VM | Get-HardDisk -ErrorAction SilentlyContinue)) {
            [void]$registered.Add($disk.Filename)
        }
        foreach ($disk in (Get-Template -ErrorAction SilentlyContinue | Get-HardDisk -ErrorAction SilentlyContinue)) {
            [void]$registered.Add($disk.Filename)
        }

        $datastores = Get-Datastore
        if ($Datastore) { $datastores = @($datastores | Where-Object { $_.Name -in $Datastore }) }

        foreach ($store in $datastores) {
            if ($store.State -ne 'Available') {
                Write-Verbose "Datastore '$($store.Name)' is not available. Skipping."
                continue
            }

            Write-Verbose "Browsing datastore '$($store.Name)' for unreferenced VMDK files."
            $driveName = 'vcds' + ([guid]::NewGuid().ToString('N').Substring(0, 6))
            try {
                New-PSDrive -Name $driveName -PSProvider VimDatastore -Root '\' -Location $store -ErrorAction Stop | Out-Null

                foreach ($file in (Get-ChildItem -Path ($driveName + ':\') -Recurse -Filter '*.vmdk' -ErrorAction SilentlyContinue)) {
                    if ($file.Name -match '-(flat|delta|ctk|sesparse)\.vmdk$') { continue }

                    $uncPath = '[{0}] {1}' -f $store.Name, ($file.DatastoreFullPath -replace '^.*\]\s*', '')
                    if ($registered.Contains($uncPath)) { continue }

                    $records += [pscustomobject]@{
                        Finding      = 'ZombieDisk'
                        Name         = $file.Name
                        Path         = $uncPath
                        Datastore    = $store.Name
                        SizeGB       = if ($file.Length) { [math]::Round($file.Length / 1GB, 2) } else { $null }
                        LastModified = $file.LastWriteTime
                        Detail       = 'No registered VM or template references this disk.'
                        ObjectId     = $null
                    }
                }
            }
            catch {
                Write-Warning ("Could not browse datastore '{0}': {1}" -f $store.Name, $_.Exception.Message)
            }
            finally {
                Remove-PSDrive -Name $driveName -Force -ErrorAction SilentlyContinue
            }
        }
    }

    $records = @($records | Sort-Object Finding, Name)
    Write-Verbose ("Collected {0} finding(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    if ($connection) { Disconnect-VIServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
