<#
.SYNOPSIS
    Lists the deployments the appliance has attempted with their current status and elapsed time.

.DESCRIPTION
    Returns each bring-up the appliance knows about with its identifier, the management domain
    name from the spec, the current status, the start time and how long it has been running or
    took to finish.

    During a bring-up the only view is a progress page nobody can share. This turns it into a
    line you can paste into a status update, and afterwards it is the record of what was
    attempted and when.

    Pain area addressed: #12 Upgrade prechecks and bundle state.

.PARAMETER Server
    FQDN or IP address of the Cloud Builder appliance.

.PARAMETER Credential
    Credential used to authenticate to the Cloud Builder appliance (default user 'admin').

.PARAMETER Status
    Limit to these statuses, for example IN_PROGRESS, COMPLETED_WITH_SUCCESS or
    COMPLETED_WITH_FAILURE.

.PARAMETER IgnoreInvalidCertificate
    Accept an untrusted or self-signed certificate on the Cloud Builder endpoint. Use only in
    lab environments.

.PARAMETER OutputPath
    Path of the file to write. When omitted the records are only returned on the pipeline and
    nothing is written to disk.

.PARAMETER Format
    Output file format. CSV is the flat table, JSON carries the export envelope that the
    matching import script validates, HTML is a styled table for sharing.

.EXAMPLE
    PS> ./Export-InstallerBringUpStatus.ps1 -Server cb.example.local -Credential $cred

    Reports the state of every bring-up this appliance has run.

.NOTES
    Author        : Sampath
    Product       : Cloud Builder (VCF 5.x)
    Target        : VMware Cloud Foundation 5.x
    Modules       : VMware.Sdk.Vcf.CloudBuilder
    Behaviour     : Read-only. Collects data and optionally writes it to disk.
    Standalone    : Yes. This script does not dot-source or import any other file
                    in this repository and can be copied out on its own.
#>

#Requires -Version 5.1
#Requires -Modules VMware.Sdk.Vcf.CloudBuilder

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Server,
    [Parameter(Mandatory)] [System.Management.Automation.PSCredential]$Credential,
    [Parameter()] [string[]]$Status,
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
    Schema        = 'installer.bringup-status'
    SchemaVersion = '1.0'
    Product       = 'vcf-installer'
    VcfVersion    = '5.x'
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
    $connection = Connect-VcfCloudBuilderServer @connectParams -ErrorAction Stop
    Write-Verbose "Connected to Cloud Builder $Server"

    $records = @()

    $deployments = Invoke-VcfGetSddcs
    Write-Verbose ("The appliance reports {0} deployment(s)." -f @($deployments.Elements).Count)

    foreach ($deployment in @($deployments.Elements)) {
        if ($Status -and $deployment.Status -notin $Status) { continue }

        $start = $null
        $end = $null
        try { if ($deployment.CreationTimestamp) { $start = [datetime]$deployment.CreationTimestamp } } catch { $start = $null }
        try { if ($deployment.CompletionTimestamp) { $end = [datetime]$deployment.CompletionTimestamp } } catch { $end = $null }

        $elapsedMinutes = $null
        if ($start) {
            $reference = if ($end) { $end } else { Get-Date }
            $elapsedMinutes = [int][math]::Round(($reference - $start).TotalMinutes, 0)
        }

        $records += [pscustomobject]@{
            SddcId         = $deployment.Id
            SddcName       = $deployment.SddcName
            Status         = $deployment.Status
            Started        = $deployment.CreationTimestamp
            Completed      = $deployment.CompletionTimestamp
            ElapsedMinutes = $elapsedMinutes
            CurrentTask    = $deployment.CurrentTask
            Message        = ($deployment.Message -replace '\s+', ' ')
        }
    }

    $records = @($records | Sort-Object Started -Descending)
    Write-Verbose ("Collected {0} deployment record(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    if ($connection) { Disconnect-VcfCloudBuilderServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
