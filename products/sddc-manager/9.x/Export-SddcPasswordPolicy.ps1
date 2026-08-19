<#
.SYNOPSIS
    Exports the password complexity, expiry and lockout policy SDDC Manager applies to each resource type.

.DESCRIPTION
    Reads the password policy for every managed resource type - minimum length, character
    classes, history, maximum and minimum age, lockout thresholds - into one table.

    Policy drifts quietly. A domain built last year has different expiry settings from one built
    this month, and nobody notices until accounts start expiring at different times. This is the
    baseline you diff against, and the file Import-SddcPasswordPolicy.ps1 replays.

    Calls GET /v1/system/security/password-policies.

    Pain area addressed: #2 Credential rotation and expiry; #16 Config portability between
    environments.

.PARAMETER Server
    FQDN or IP address of the SDDC Manager appliance.

.PARAMETER Credential
    Credential used to authenticate to SDDC Manager (for example administrator@vsphere.local).

.PARAMETER ResourceType
    Limit to these resource types, for example SSO, VCENTER, ESXI or NSXT_MANAGER.

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
    PS> ./Export-SddcPasswordPolicy.ps1 -Server sddc.example.local -Credential $cred -OutputPath ./policy.json -Format JSON

    Captures the current policy as the baseline for another instance.

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
    [Parameter()] [string[]]$ResourceType,
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
    Schema        = 'vcf.sddc.password-policy'
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

    $policies = Invoke-VcfGetPasswordPolicies
    Write-Verbose ("Retrieved policy for {0} resource type(s)." -f @($policies.Elements).Count)

    foreach ($policy in @($policies.Elements)) {
        if ($ResourceType -and $policy.ResourceType -notin $ResourceType) { continue }

        $records += [pscustomobject]@{
            ResourceType        = $policy.ResourceType
            MinLength           = $policy.PasswordComplexity.MinLength
            MaxLength           = $policy.PasswordComplexity.MaxLength
            MinLowercase        = $policy.PasswordComplexity.MinLowercaseCharacters
            MinUppercase        = $policy.PasswordComplexity.MinUppercaseCharacters
            MinNumeric          = $policy.PasswordComplexity.MinNumericCharacters
            MinSpecial          = $policy.PasswordComplexity.MinSpecialCharacters
            History             = $policy.PasswordComplexity.History
            MaxAgeDays          = $policy.PasswordExpiration.MaxDays
            MinAgeDays          = $policy.PasswordExpiration.MinDays
            WarningDays         = $policy.PasswordExpiration.WarningDays
            LockoutFailures     = $policy.AccountLockout.MaxFailedAttempts
            LockoutIntervalSec  = $policy.AccountLockout.UnlockIntervalInSecond
        }
    }

    $records = @($records | Sort-Object ResourceType)
    Write-Verbose ("Collected policy for {0} resource type(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    if ($connection) { Disconnect-VcfSddcManagerServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
