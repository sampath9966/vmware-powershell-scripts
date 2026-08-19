<#
.SYNOPSIS
    Lists currently active alerts joined to the object they fired on and how long they have been open.

.DESCRIPTION
    Returns every active alert with its criticality, status, the resource it fired against, the
    alert definition that produced it, and the age in hours - so long-running and repeatedly
    firing alerts are visible rather than lost in a scrolling list.

    Alert noise reduction always starts with 'what is actually firing and how often', and that
    is a grouping question. Group this by AlertDefinition and the top three rows are usually the
    whole problem.

    Pain area addressed: #13 Alarm noise and audit-trail extraction.

.PARAMETER Server
    FQDN or IP address of the VCF Operations (Aria Operations) analytics node.

.PARAMETER Credential
    Credential used to authenticate to VCF Operations.

.PARAMETER Criticality
    Limit to these criticality levels, for example Critical, Immediate or Warning.

.PARAMETER OlderThanHours
    Return only alerts that have been active for at least this long.

.PARAMETER OutputPath
    Path of the file to write. When omitted the records are only returned on the pipeline and
    nothing is written to disk.

.PARAMETER Format
    Output file format. CSV is the flat table, JSON carries the export envelope that the
    matching import script validates, HTML is a styled table for sharing.

.EXAMPLE
    PS> ./Export-OpsActiveAlert.ps1 -Server ops.example.local -Credential $cred | Group-Object AlertDefinition | Sort-Object Count -Descending

    Ranks alert definitions by how much noise each is producing.

.NOTES
    Author        : Sampath
    Product       : VCF Operations (VCF 9.x)
    Target        : VMware Cloud Foundation 9.x
    Modules       : VMware.VimAutomation.vROps
    Behaviour     : Read-only. Collects data and optionally writes it to disk.
    Standalone    : Yes. This script does not dot-source or import any other file
                    in this repository and can be copied out on its own.
#>

#Requires -Version 5.1
#Requires -Modules VMware.VimAutomation.vROps

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Server,
    [Parameter(Mandatory)] [System.Management.Automation.PSCredential]$Credential,
    [Parameter()] [string[]]$Criticality,
    [Parameter()] [int]$OlderThanHours = 0,
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
    Schema        = 'vcf-operations.active-alert'
    SchemaVersion = '1.0'
    Product       = 'vcf-operations'
    VcfVersion    = '9.x'
    Server        = $Server
}

$connection = $null
try {
    $connection = Connect-OMServer -Server $Server -Credential $Credential -ErrorAction Stop
    Write-Verbose "Connected to VCF Operations $($connection.Name)"

    $records = @()

    $alerts = Get-OMAlert -Status Active
    Write-Verbose ("Operations reports {0} active alert(s)." -f @($alerts).Count)

    foreach ($alert in $alerts) {
        if ($Criticality -and [string]$alert.Criticality -notin $Criticality) { continue }

        $ageHours = $null
        if ($alert.StartTime) {
            $ageHours = [int][math]::Floor(((Get-Date) - $alert.StartTime).TotalHours)
        }

        if ($OlderThanHours -gt 0 -and ($null -eq $ageHours -or $ageHours -lt $OlderThanHours)) { continue }

        $records += [pscustomobject]@{
            AlertId         = $alert.Id
            AlertDefinition = $alert.AlertDefinition
            Criticality     = [string]$alert.Criticality
            Status          = [string]$alert.Status
            Resource        = [string]$alert.Resource
            ResourceKind    = $alert.Resource.ResourceKind
            StartTime       = $alert.StartTime
            AgeHours        = $ageHours
            Impact          = $alert.Impact
            Description     = ($alert.Description -replace '\s+', ' ')
        }
    }

    $records = @($records | Sort-Object AgeHours -Descending)
    Write-Verbose ("Collected {0} active alert(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    if ($connection) { Disconnect-OMServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
