<#
.SYNOPSIS
    Exports custom roles with their privilege lists, plus every permission assignment and where it propagates.

.DESCRIPTION
    Two things in one file: the custom roles defined in this vCenter with the exact privilege
    list each one grants, and every permission assignment - which principal, on which inventory
    object, through which role, propagating or not.

    This is the answer to 'who can do what here', which normally means clicking through the
    permissions tab of every object. It is also the only practical way to rebuild an access
    model in a DR vCenter, which is what Import-VcPermission.ps1 does with the same file.

    Pain area addressed: #16 Config portability between environments; #13 Alarm noise and
    audit-trail extraction.

.PARAMETER Server
    FQDN or IP address of the vCenter Server to connect to.

.PARAMETER Credential
    Credential used to authenticate to vCenter Server.

.PARAMETER IncludeSystemRole
    Include the built-in system roles. Off by default because they are identical everywhere.

.PARAMETER Principal
    Limit assignments to these principals. Accepts wildcards.

.PARAMETER OutputPath
    Path of the file to write. When omitted the records are only returned on the pipeline and
    nothing is written to disk.

.PARAMETER Format
    Output file format. CSV is the flat table, JSON carries the export envelope that the
    matching import script validates, HTML is a styled table for sharing.

.EXAMPLE
    PS> ./Export-VcPermission.ps1 -Server vcenter.example.local -Credential $cred -OutputPath ./rbac.json -Format JSON

    Captures the whole access model, ready to replay.

.EXAMPLE
    PS> ./Export-VcPermission.ps1 -Server vcenter.example.local -Credential $cred | Where-Object Kind -eq 'Permission' | Group-Object Role

    Shows how heavily each role is actually used.

.NOTES
    Author        : Sampath
    Product       : vCenter (VCF 9.x)
    Target        : VMware Cloud Foundation 9.x
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
    [Parameter()] [switch]$IncludeSystemRole,
    [Parameter()] [string[]]$Principal,
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
    Schema        = 'vcenter.permission'
    SchemaVersion = '1.0'
    Product       = 'vcenter'
    VcfVersion    = '9.x'
    Server        = $Server
}

$connection = $null
try {
    $connection = Connect-VIServer -Server $Server -Credential $Credential -ErrorAction Stop
    Write-Verbose "Connected to vCenter Server $($connection.Name) (version $($connection.Version))"

    $records = @()

    foreach ($role in (Get-VIRole)) {
        if (-not $IncludeSystemRole -and $role.IsSystem) { continue }

        $records += [pscustomobject]@{
            Kind       = 'Role'
            Role       = $role.Name
            IsSystem   = $role.IsSystem
            Privileges = (($role.PrivilegeList | Sort-Object) -join '; ')
            Principal  = ''
            Entity     = ''
            EntityType = ''
            Propagate  = $null
            IsGroup    = $null
        }
    }

    foreach ($permission in (Get-VIPermission)) {
        if ($Principal) {
            $match = $false
            foreach ($pattern in $Principal) { if ($permission.Principal -like $pattern) { $match = $true; break } }
            if (-not $match) { continue }
        }

        $records += [pscustomobject]@{
            Kind       = 'Permission'
            Role       = $permission.Role
            IsSystem   = $null
            Privileges = ''
            Principal  = $permission.Principal
            Entity     = $permission.Entity.Name
            EntityType = ($permission.Entity.GetType().Name -replace 'Impl$', '')
            Propagate  = $permission.Propagate
            IsGroup    = $permission.IsGroup
        }
    }

    $records = @($records | Sort-Object Kind, Role, Principal)
    Write-Verbose ("Collected {0} role and permission row(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    if ($connection) { Disconnect-VIServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
