<#
.SYNOPSIS
    Exports tag categories, tags and every object assignment as a replayable file.

.DESCRIPTION
    Captures the whole tagging model: each category with its cardinality and associable types,
    each tag inside it, and every assignment to a VM, host, datastore or cluster.

    Tags drive backup selection, DR policy and chargeback, and they are the first thing lost
    when an environment is rebuilt or a second site is stood up. Nothing in the UI exports them.
    This file plus Import-VcTagAssignment.ps1 makes the model portable.

    Pain area addressed: #16 Config portability between environments; #10 Cross-domain
    inventory.

.PARAMETER Server
    FQDN or IP address of the vCenter Server to connect to.

.PARAMETER Credential
    Credential used to authenticate to vCenter Server.

.PARAMETER Category
    Limit the export to these tag categories.

.PARAMETER EntityType
    Limit assignments to these entity types, for example VirtualMachine, VMHost or Datastore.

.PARAMETER OutputPath
    Path of the file to write. When omitted the records are only returned on the pipeline and
    nothing is written to disk.

.PARAMETER Format
    Output file format. CSV is the flat table, JSON carries the export envelope that the
    matching import script validates, HTML is a styled table for sharing.

.EXAMPLE
    PS> ./Export-VcTagAssignment.ps1 -Server vcenter.example.local -Credential $cred -OutputPath ./tags.json -Format JSON

    Captures the whole tagging model ready to replay into another vCenter.

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
    [Parameter()] [string[]]$Category,
    [Parameter()] [string[]]$EntityType,
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
    Schema        = 'vcenter.tag-assignment'
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

    $records = @()

    $categories = Get-TagCategory
    if ($Category) { $categories = @($categories | Where-Object { $_.Name -in $Category }) }
    Write-Verbose ("Found {0} tag category/categories." -f @($categories).Count)

    foreach ($tagCategory in $categories) {
        $tags = @(Get-Tag -Category $tagCategory -ErrorAction SilentlyContinue)

        if (-not $tags) {
            $records += [pscustomobject]@{
                Category            = $tagCategory.Name
                CategoryDescription = $tagCategory.Description
                Cardinality         = [string]$tagCategory.Cardinality
                EntityTypes         = ($tagCategory.EntityType -join '; ')
                Tag                 = ''
                TagDescription      = ''
                EntityName          = ''
                EntityType          = ''
            }
            continue
        }

        foreach ($tag in $tags) {
            $assignments = @(Get-TagAssignment -Tag $tag -ErrorAction SilentlyContinue)

            if (-not $assignments) {
                $records += [pscustomobject]@{
                    Category            = $tagCategory.Name
                    CategoryDescription = $tagCategory.Description
                    Cardinality         = [string]$tagCategory.Cardinality
                    EntityTypes         = ($tagCategory.EntityType -join '; ')
                    Tag                 = $tag.Name
                    TagDescription      = $tag.Description
                    EntityName          = ''
                    EntityType          = ''
                }
                continue
            }

            foreach ($assignment in $assignments) {
                $type = $assignment.Entity.GetType().Name -replace 'Impl$', ''
                if ($EntityType -and $type -notin $EntityType) { continue }

                $records += [pscustomobject]@{
                    Category            = $tagCategory.Name
                    CategoryDescription = $tagCategory.Description
                    Cardinality         = [string]$tagCategory.Cardinality
                    EntityTypes         = ($tagCategory.EntityType -join '; ')
                    Tag                 = $tag.Name
                    TagDescription      = $tag.Description
                    EntityName          = $assignment.Entity.Name
                    EntityType          = $type
                }
            }
        }
    }

    $records = @($records | Sort-Object Category, Tag, EntityName)
    Write-Verbose ("Collected {0} tag row(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    if ($connection) { Disconnect-VIServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
