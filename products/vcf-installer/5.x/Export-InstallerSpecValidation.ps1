<#
.SYNOPSIS
    Submits a deployment spec for validation and returns one flat row per validation check.

.DESCRIPTION
    Reads a deployment spec JSON file, submits it for validation, waits for the run to finish
    and returns each check as a row with its name, the resource it applied to, its result and
    the error and remediation text.

    Validation is the step that saves a rebuild, and its output is a nested tree that cannot be
    exported. This makes it reviewable, filterable and attachable to a change record - and it
    validates only, it never deploys.

    Pain area addressed: #12 Upgrade prechecks and bundle state.

.PARAMETER Server
    FQDN or IP address of the Cloud Builder appliance.

.PARAMETER Credential
    Credential used to authenticate to the Cloud Builder appliance (default user 'admin').

.PARAMETER SpecPath
    Path to the deployment spec JSON file to validate.

.PARAMETER FailuresOnly
    Return only checks that did not pass.

.PARAMETER TimeoutMinutes
    How long to wait for validation to finish. Defaults to 45.

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
    PS> ./Export-InstallerSpecValidation.ps1 -Server cb.example.local -Credential $cred -SpecPath ./sddc-spec.json -FailuresOnly

    Validates the spec and lists only what would block the deployment.

.EXAMPLE
    PS> ./Export-InstallerSpecValidation.ps1 -Server cb.example.local -Credential $cred -SpecPath ./sddc-spec.json -OutputPath ./validation.html -Format HTML

    Produces a shareable validation report for the change record.

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
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$SpecPath,
    [Parameter()] [switch]$FailuresOnly,
    [Parameter()] [int]$TimeoutMinutes = 45,
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
    Schema        = 'installer.spec-validation'
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
    # Scope every call in this script to the connection opened above. Without this,
    # PowerCLI cmdlets act on every connected server, which silently mixes inventories
    # when more than one is connected. The hashtable is cloned first because indexing
    # the inherited one would change the caller's session defaults too.
    $PSDefaultParameterValues = $PSDefaultParameterValues.Clone()
    $PSDefaultParameterValues['*:Server'] = $connection

    $records = @()

    if (-not (Test-Path -LiteralPath $SpecPath)) { throw "Spec file not found: $SpecPath" }

    $spec = Get-Content -LiteralPath $SpecPath -Raw | ConvertFrom-Json
    Write-Verbose ("Submitting '{0}' for validation. This validates only; nothing is deployed." -f $SpecPath)

    $validation = Invoke-VcfValidateSddcSpec -SddcSpec $spec

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $deadline) {
        $validation = Invoke-VcfGetSddcValidation -Id $validation.Id
        if ($validation.ExecutionStatus -in @('COMPLETED', 'FAILED', 'CANCELLED')) { break }
        Start-Sleep -Seconds 15
    }
    Write-Verbose ("Validation finished with execution status '{0}' and result '{1}'." -f $validation.ExecutionStatus, $validation.ResultStatus)

    foreach ($check in @($validation.ValidationChecks)) {
        $result = $check.ResultStatus
        if ($FailuresOnly -and $result -in @('SUCCEEDED', 'PASSED')) { continue }

        $records += [pscustomobject]@{
            ValidationId    = $validation.Id
            SpecFile        = (Split-Path $SpecPath -Leaf)
            CheckName       = $check.Description
            ResultStatus    = $result
            Severity        = $check.Severity
            NestedChecks    = @($check.NestedValidationChecks).Count
            ErrorCode       = $check.ErrorResponse.ErrorCode
            Message         = ($check.ErrorResponse.Message -replace '\s+', ' ')
            Remediation     = ($check.ErrorResponse.RemediationMessage -replace '\s+', ' ')
        }

        foreach ($nested in @($check.NestedValidationChecks)) {
            $nestedResult = $nested.ResultStatus
            if ($FailuresOnly -and $nestedResult -in @('SUCCEEDED', 'PASSED')) { continue }

            $records += [pscustomobject]@{
                ValidationId = $validation.Id
                SpecFile     = (Split-Path $SpecPath -Leaf)
                CheckName    = ('  ' + $nested.Description)
                ResultStatus = $nestedResult
                Severity     = $nested.Severity
                NestedChecks = 0
                ErrorCode    = $nested.ErrorResponse.ErrorCode
                Message      = ($nested.ErrorResponse.Message -replace '\s+', ' ')
                Remediation  = ($nested.ErrorResponse.RemediationMessage -replace '\s+', ' ')
            }
        }
    }

    $records = @($records | Sort-Object ResultStatus, CheckName)
    Write-Verbose ("Collected {0} validation finding(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    if ($connection) { Disconnect-VcfCloudBuilderServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
