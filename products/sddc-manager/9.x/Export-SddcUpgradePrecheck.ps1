<#
.SYNOPSIS
    Runs an SDDC Manager precheck and flattens the nested result tree into one row per finding.

.DESCRIPTION
    Starts a system or domain precheck, waits for it to finish, then walks the nested result
    tree and returns one flat row per check - name, resource, status and the remediation text -
    instead of the collapsible tree the UI shows.

    The tree view is the problem: a failed precheck buries three real findings under forty green
    ones, and there is no way to hand that to anyone. Filter this output to Status -ne
    'SUCCEEDED' and you have the actual blocker list for the change record.

    Calls POST /v1/system/prechecks and polls GET /v1/system/prechecks/tasks/{id}.

    Pain area addressed: #12 Upgrade prechecks and bundle state.

.PARAMETER Server
    FQDN or IP address of the SDDC Manager appliance.

.PARAMETER Credential
    Credential used to authenticate to SDDC Manager (for example administrator@vsphere.local).

.PARAMETER DomainName
    Run the precheck against these workload domains only. Omit to precheck the whole system.

.PARAMETER FailuresOnly
    Return only findings that did not succeed.

.PARAMETER TimeoutMinutes
    How long to wait for the precheck to complete. Defaults to 60.

.PARAMETER IgnoreInvalidCertificate
    Accept an untrusted or self-signed certificate on the SDDC Manager endpoint. Use only in lab
    environments.

.PARAMETER OutputPath
    Path of the file to write. When omitted the records are only returned on the pipeline and
    nothing is written to disk.

.PARAMETER Format
    Output file format. CSV is the flat table, JSON carries the export envelope that the
    matching import script validates, HTML is a styled table for sharing.

.EXAMPLE
    PS> ./Export-SddcUpgradePrecheck.ps1 -Server sddc.example.local -Credential $cred -FailuresOnly

    Runs a full system precheck and returns only what is actually blocking.

.EXAMPLE
    PS> ./Export-SddcUpgradePrecheck.ps1 -Server sddc.example.local -Credential $cred -OutputPath ./precheck.html -Format HTML

    Produces a shareable precheck report for a change record.

.NOTES
    Author        : Sampath
    Product       : SDDC Manager (VCF 9.x)
    Target        : VMware Cloud Foundation 9.x
    Modules       : VMware.Sdk.Vcf.SddcManager
    Behaviour     : Read-only. Collects data and optionally writes it to disk.
    Standalone    : Yes. This script does not dot-source or import any other file
                    in this repository and can be copied out on its own.
#>

#Requires -Version 5.1
#Requires -Modules VMware.Sdk.Vcf.SddcManager

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Server,
    [Parameter(Mandatory)] [System.Management.Automation.PSCredential]$Credential,
    [Parameter()] [string[]]$DomainName,
    [Parameter()] [switch]$FailuresOnly,
    [Parameter()] [int]$TimeoutMinutes = 60,
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
    Schema        = 'vcf.sddc.upgrade-precheck'
    SchemaVersion = '1.0'
    Product       = 'sddc-manager'
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
    $connection = Connect-VcfSddcManagerServer @connectParams -ErrorAction Stop
    Write-Verbose "Connected to SDDC Manager $Server"
    # Scope every call in this script to the connection opened above. Without this,
    # PowerCLI cmdlets act on every connected server, which silently mixes inventories
    # when more than one is connected. The hashtable is cloned first because indexing
    # the inherited one would change the caller's session defaults too.
    $PSDefaultParameterValues = $PSDefaultParameterValues.Clone()
    $PSDefaultParameterValues['*:Server'] = $connection

    $records = @()

    $resources = @()
    if ($DomainName) {
        foreach ($domain in @((Invoke-VcfGetDomains).Elements)) {
            if ($domain.Name -in $DomainName) {
                $resources += Initialize-VcfPrecheckResource -Type 'DOMAIN' -ResourceId $domain.Id
            }
        }
        if (-not $resources) { throw "No workload domain matched -DomainName." }
    }
    else {
        $resources += Initialize-VcfPrecheckResource -Type 'SYSTEM'
    }

    $spec = Initialize-VcfPrecheckSpec -Resources @($resources)
    $task = Invoke-VcfPerformPrecheck -PrecheckSpec $spec
    Write-Verbose "Precheck task $($task.Id) submitted. Waiting for it to complete."

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $deadline) {
        $task = Invoke-VcfGetPrecheckTask -Id $task.Id
        if ($task.Status -in @('SUCCESSFUL', 'FAILED', 'CANCELLED', 'COMPLETED_WITH_FAILURE')) { break }
        Start-Sleep -Seconds 20
    }
    Write-Verbose "Precheck finished with status '$($task.Status)'."

    foreach ($resource in @($task.Resources)) {
        foreach ($check in @($resource.PrecheckResults)) {
            if ($FailuresOnly -and $check.Status -eq 'SUCCEEDED') { continue }

            $records += [pscustomobject]@{
                TaskId       = $task.Id
                ResourceType = $resource.Type
                ResourceName = $resource.Name
                CheckName    = $check.Name
                Status       = $check.Status
                Severity     = $check.Severity
                Message      = $check.Messages.Message -join ' '
                Remediation  = $check.Messages.Remediation -join ' '
            }
        }
    }

    $records = @($records | Sort-Object Status, ResourceName, CheckName)
    Write-Verbose ("Collected {0} precheck finding(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    if ($connection) { Disconnect-VcfSddcManagerServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
