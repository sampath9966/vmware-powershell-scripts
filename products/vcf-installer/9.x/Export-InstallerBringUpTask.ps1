<#
.SYNOPSIS
    Flattens the nested bring-up task and subtask tree into one row per step with its status and error.

.DESCRIPTION
    Walks the task tree of a bring-up and returns one row per task and subtask carrying its
    name, phase, status, duration and the error text where it failed - instead of the
    collapsible tree the appliance shows.

    When a bring-up fails at three in the morning, the useful information is four levels deep in
    that tree behind a dozen green ticks. Filtering this to Status -ne 'SUCCESSFUL' puts the
    failure on the first row.

    Pain area addressed: #12 Upgrade prechecks and bundle state.

.PARAMETER Server
    FQDN or IP address of the VCF Installer appliance.

.PARAMETER Credential
    Credential used to authenticate to the VCF Installer appliance.

.PARAMETER SddcId
    Identifier of the bring-up to expand. Omit to use the most recent one.

.PARAMETER FailuresOnly
    Return only tasks and subtasks that did not succeed.

.PARAMETER IgnoreInvalidCertificate
    Accept an untrusted or self-signed certificate on the VCF Installer endpoint. Use only in
    lab environments.

.PARAMETER OutputPath
    Path of the file to write. When omitted the records are only returned on the pipeline and
    nothing is written to disk.

.PARAMETER Format
    Output file format. CSV is the flat table, JSON carries the export envelope that the
    matching import script validates, HTML is a styled table for sharing.

.EXAMPLE
    PS> ./Export-InstallerBringUpTask.ps1 -Server cb.example.local -Credential $cred -FailuresOnly

    Shows only the steps that failed in the most recent bring-up.

.NOTES
    Author        : Sampath
    Product       : VCF Installer (VCF 9.x)
    Target        : VMware Cloud Foundation 9.x
    Modules       : VMware.Sdk.Vcf.Installer
    Behaviour     : Read-only. Collects data and optionally writes it to disk.
    Standalone    : Yes. This script does not dot-source or import any other file
                    in this repository and can be copied out on its own.
#>

#Requires -Version 5.1
#Requires -Modules VMware.Sdk.Vcf.Installer

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Server,
    [Parameter(Mandatory)] [System.Management.Automation.PSCredential]$Credential,
    [Parameter()] [string]$SddcId,
    [Parameter()] [switch]$FailuresOnly,
    [Parameter()] [switch]$IgnoreInvalidCertificate,
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
    Schema        = 'installer.bringup-task'
    SchemaVersion = '1.0'
    Product       = 'vcf-installer'
    VcfVersion    = '9.x'
    Server        = $Server
}

$connection = $null
try {
    $connectParams = @{
        Server   = $Server
        User     = $Credential.UserName
        Password = $Credential.GetNetworkCredential().Password
    }
    if ($IgnoreInvalidCertificate) { $connectParams['IgnoreInvalidCertificate'] = $true }
    $connection = Connect-VcfInstallerServer @connectParams -ErrorAction Stop
    Write-Verbose "Connected to VCF Installer $Server"
    # Scope every call in this script to the connection opened above. Without this,
    # PowerCLI cmdlets act on every connected server, which silently mixes inventories
    # when more than one is connected. The hashtable is cloned first because indexing
    # the inherited one would change the caller's session defaults too.
    $PSDefaultParameterValues = $PSDefaultParameterValues.Clone()
    $PSDefaultParameterValues['*:Server'] = $connection

    $records = @()

    $targetId = $SddcId
    if (-not $targetId) {
        $latest = @((Invoke-VcfGetSddcs).Elements | Sort-Object CreationTimestamp -Descending) | Select-Object -First 1
        if (-not $latest) { throw 'The appliance has no deployments to report on.' }
        $targetId = $latest.Id
        Write-Verbose "No -SddcId given; using the most recent deployment $targetId."
    }

    $deployment = Invoke-VcfGetSddc -Id $targetId
    Write-Verbose ("Expanding the task tree for deployment '{0}' (status {1})." -f $targetId, $deployment.Status)

    foreach ($task in @($deployment.SddcSubTasks)) {
        $start = $null
        $end = $null
        try { if ($task.StartTime) { $start = [datetime]$task.StartTime } } catch { $start = $null }
        try { if ($task.EndTime) { $end = [datetime]$task.EndTime } } catch { $end = $null }

        $status = $task.Status
        if (-not ($FailuresOnly -and $status -eq 'SUCCESSFUL')) {
            $records += [pscustomobject]@{
                SddcId          = $targetId
                Level           = 'Task'
                Name            = $task.Name
                Phase           = $task.SddcPhaseName
                Description     = ($task.Description -replace '\s+', ' ')
                Status          = $status
                Started         = $task.StartTime
                Ended           = $task.EndTime
                DurationMinutes = if ($start -and $end) { [int][math]::Round(($end - $start).TotalMinutes, 0) } else { $null }
                Errors          = (@($task.Errors.Message) -join '; ')
            }
        }

        foreach ($subTask in @($task.SubTasks)) {
            $subStatus = $subTask.Status
            if ($FailuresOnly -and $subStatus -eq 'SUCCESSFUL') { continue }

            $subStart = $null
            $subEnd = $null
            try { if ($subTask.StartTime) { $subStart = [datetime]$subTask.StartTime } } catch { $subStart = $null }
            try { if ($subTask.EndTime) { $subEnd = [datetime]$subTask.EndTime } } catch { $subEnd = $null }

            $records += [pscustomobject]@{
                SddcId          = $targetId
                Level           = 'SubTask'
                Name            = $subTask.Name
                Phase           = $task.SddcPhaseName
                Description     = ($subTask.Description -replace '\s+', ' ')
                Status          = $subStatus
                Started         = $subTask.StartTime
                Ended           = $subTask.EndTime
                DurationMinutes = if ($subStart -and $subEnd) { [int][math]::Round(($subEnd - $subStart).TotalMinutes, 0) } else { $null }
                Errors          = (@($subTask.Errors.Message) -join '; ')
            }
        }
    }

    Write-Verbose ("Collected {0} task row(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    if ($connection) { Disconnect-VcfInstallerServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
