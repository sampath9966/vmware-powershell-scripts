<#
.SYNOPSIS
    Cross-checks Supervisor namespaces against tag-based backup selection and reports the ones nothing protects.

.DESCRIPTION
    Lists every namespace and the VMs in it, then checks each VM against the backup selection
    tag category you nominate. Namespaces where no VM carries a protection tag come back as
    Unprotected, and partially tagged namespaces come back as Partial.

    Backup selection for Kubernetes workloads is usually tag-driven and set up once, and new
    namespaces appear constantly without anyone adding them. This is the gap report that nobody
    runs until the restore fails.

    Pain area addressed: #15 Protection gaps.

.PARAMETER Server
    FQDN or IP address of the vCenter Server that hosts the Supervisor.

.PARAMETER Credential
    Credential used to authenticate to vCenter Server. Needs Namespaces privileges to read or
    change namespace configuration.

.PARAMETER ProtectionTagCategory
    Tag category used by the backup product to select workloads. Defaults to 'Backup'.

.PARAMETER UnprotectedOnly
    Return only namespaces with no protection at all.

.PARAMETER OutputPath
    Path of the file to write. When omitted the records are only returned on the pipeline and
    nothing is written to disk.

.PARAMETER Format
    Output file format. CSV is the flat table, JSON carries the export envelope that the
    matching import script validates, HTML is a styled table for sharing.

.EXAMPLE
    PS> ./Export-SupervisorProtectionGap.ps1 -Server vcenter.example.local -Credential $cred -ProtectionTagCategory 'K8sBackup' -UnprotectedOnly

    Lists namespaces the backup policy does not cover.

.NOTES
    Author        : Sampath
    Product       : vSphere with Tanzu (Supervisor and TKG) (VCF 5.x)
    Target        : VMware Cloud Foundation 5.x
    Modules       : VMware.VimAutomation.Core, VMware.VimAutomation.WorkloadManagement, VMware.VimAutomation.Cis.Core
    Behaviour     : Read-only. Collects data and optionally writes it to disk.
    Standalone    : Yes. This script does not dot-source or import any other file
                    in this repository and can be copied out on its own.
#>

#Requires -Version 5.1
#Requires -Modules VMware.VimAutomation.Core
#Requires -Modules VMware.VimAutomation.WorkloadManagement
#Requires -Modules VMware.VimAutomation.Cis.Core

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Server,
    [Parameter(Mandatory)] [System.Management.Automation.PSCredential]$Credential,
    [Parameter()] [string]$ProtectionTagCategory = 'Backup',
    [Parameter()] [switch]$UnprotectedOnly,
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
    Schema        = 'supervisor.protection-gap'
    SchemaVersion = '1.0'
    Product       = 'vsphere-supervisor'
    VcfVersion    = '5.x'
    Server        = $Server
}

$connection = $null
try {
    $connection = Connect-VIServer -Server $Server -Credential $Credential -ErrorAction Stop
    $cisConnection = Connect-CisServer -Server $Server -Credential $Credential -ErrorAction Stop
    if (@($DefaultVIServers).Count -gt 1) {
        Write-Warning (("{0} vCenter connections are open in this session. PowerCLI cmdlets act on " +
            "every connected server unless they are scoped, which silently mixes inventories. " +
            "This script scopes its own calls to '{1}'.") -f @($DefaultVIServers).Count, $connection.Name)
    }
    Write-Verbose "Connected to vCenter Server $($connection.Name) and its Automation API endpoint"
    # Scope every call in this script to the connection opened above. Without this,
    # PowerCLI cmdlets act on every connected server, which silently mixes inventories
    # when more than one is connected. The hashtable is cloned first because indexing
    # the inherited one would change the caller's session defaults too.
    $PSDefaultParameterValues = $PSDefaultParameterValues.Clone()
    $PSDefaultParameterValues['*:Server'] = $connection

    $records = @()

    $namespaceService = Get-CisService -Name 'com.vmware.vcenter.namespaces.instances' -Server $cisConnection -ErrorAction Stop
    $namespaceNames = @(@($namespaceService.list()).namespace)
    Write-Verbose ("Checking {0} namespace(s) against tag category '{1}'." -f $namespaceNames.Count, $ProtectionTagCategory)

    $category = Get-TagCategory -Name $ProtectionTagCategory -ErrorAction SilentlyContinue
    if (-not $category) {
        Write-Warning "Tag category '$ProtectionTagCategory' does not exist in this vCenter. Every namespace will report as unprotected."
    }

    $taggedVmIds = @{}
    if ($category) {
        foreach ($assignment in (Get-TagAssignment -Category $category -ErrorAction SilentlyContinue)) {
            $taggedVmIds[$assignment.Entity.Id] = $assignment.Tag.Name
        }
        Write-Verbose ("{0} object(s) carry a tag in that category." -f $taggedVmIds.Count)
    }

    foreach ($namespace in $namespaceNames) {
        $folder = Get-Folder -Name $namespace -ErrorAction SilentlyContinue
        $vms = @()
        if ($folder) { $vms = @(Get-VM -Location $folder -ErrorAction SilentlyContinue) }

        $protected = @($vms | Where-Object { $taggedVmIds.ContainsKey($_.Id) })

        $verdict = if ($vms.Count -eq 0) { 'Empty' }
                   elseif ($protected.Count -eq 0) { 'Unprotected' }
                   elseif ($protected.Count -lt $vms.Count) { 'Partial' }
                   else { 'Protected' }

        if ($UnprotectedOnly -and $verdict -notin @('Unprotected', 'Partial')) { continue }

        $records += [pscustomobject]@{
            Namespace      = $namespace
            VmCount        = $vms.Count
            ProtectedCount = $protected.Count
            Verdict        = $verdict
            ProtectionTags = (@($protected | ForEach-Object { $taggedVmIds[$_.Id] } | Sort-Object -Unique) -join '; ')
            UnprotectedVms = (@($vms | Where-Object { -not $taggedVmIds.ContainsKey($_.Id) }).Name -join '; ')
        }
    }

    $records = @($records | Sort-Object Verdict, Namespace)
    Write-Verbose ("Collected {0} namespace protection row(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    if ($cisConnection) { Disconnect-CisServer -Server $cisConnection -Confirm:$false -ErrorAction SilentlyContinue }
    if ($connection) { Disconnect-VIServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
