<#
.SYNOPSIS
    Lists every account SDDC Manager manages, with password age and rotation state - without revealing any password.

.DESCRIPTION
    Pulls the full managed credential list - ESX root, vCenter SSO and appliance accounts, NSX
    admin and audit accounts, the backup user - and reports when each password was last changed,
    how old it is now, and whether SDDC Manager currently considers it valid.

    Passwords are deliberately never placed in the output. The point of this export is the
    metadata: which accounts are drifting towards expiry, which failed their last rotation, and
    which resources are missing an account type you expected them to have. That is the list you
    cannot get from the UI without clicking through every resource.

    Calls GET /v1/credentials.

    Pain area addressed: #2 Credential rotation and expiry.

.PARAMETER Server
    FQDN or IP address of the SDDC Manager appliance.

.PARAMETER Credential
    Credential used to authenticate to SDDC Manager (for example administrator@vsphere.local).

.PARAMETER ResourceType
    Limit to these resource types, for example ESXI, VCENTER, NSXT_MANAGER, PSC or BACKUP.

.PARAMETER AccountType
    Limit to these account types, typically USER, SYSTEM or SERVICE.

.PARAMETER OlderThanDays
    Return only credentials whose password was last changed more than this many days ago. Omit
    for all.

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
    PS> ./Export-SddcCredentialInventory.ps1 -Server sddc.example.local -Credential $cred -OlderThanDays 80 -OutputPath ./creds.json -Format JSON

    Writes every managed account whose password is over 80 days old - the input
    Invoke-SddcCredentialRotation.ps1 expects.

.EXAMPLE
    PS> ./Export-SddcCredentialInventory.ps1 -Server sddc.example.local -Credential $cred -ResourceType ESXI | Where-Object Status -ne 'ACTIVE'

    Finds ESX host accounts that are not in a healthy state - usually the cause of a domain
    stuck in error.

.NOTES
    Author        : Sampath
    Product       : SDDC Manager (VCF 5.x)
    Target        : VMware Cloud Foundation 5.x
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
    [Parameter()] [string[]]$AccountType,
    [Parameter()] [int]$OlderThanDays = 0,
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
    Schema        = 'vcf.sddc.credential-inventory'
    SchemaVersion = '1.0'
    Product       = 'sddc-manager'
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
    $connection = Connect-VcfSddcManagerServer @connectParams -ErrorAction Stop
    Write-Verbose "Connected to SDDC Manager $Server"

    $records = @()

    $credentials = Invoke-VcfGetCredentials
    Write-Verbose ("SDDC Manager reports {0} managed credential(s)." -f @($credentials.Elements).Count)

    foreach ($credential in @($credentials.Elements)) {
        if ($ResourceType -and $credential.Resource.ResourceType -notin $ResourceType) { continue }
        if ($AccountType -and $credential.AccountType -notin $AccountType) { continue }

        $modified = $null
        if ($credential.ModificationTimestamp) {
            try { $modified = [datetime]$credential.ModificationTimestamp } catch { $modified = $null }
        }

        $ageDays = $null
        if ($modified) {
            $ageDays = [int][math]::Floor(((Get-Date) - $modified).TotalDays)
        }

        if ($OlderThanDays -gt 0) {
            if ($null -eq $ageDays -or $ageDays -lt $OlderThanDays) { continue }
        }

        $records += [pscustomobject]@{
            ResourceName     = $credential.Resource.ResourceName
            ResourceFqdn     = $credential.Resource.ResourceIp
            ResourceType     = $credential.Resource.ResourceType
            DomainName       = $credential.Resource.DomainName
            Username         = $credential.Username
            AccountType      = $credential.AccountType
            CredentialType   = $credential.CredentialType
            Status           = $credential.Status
            AutoRotatePolicy = $credential.AutoRotatePolicy.FrequencyInDays
            LastModified     = $credential.ModificationTimestamp
            PasswordAgeDays  = $ageDays
        }
    }

    $records = @($records | Sort-Object -Property @{ Expression = { if ($null -eq $_.PasswordAgeDays) { -1 } else { $_.PasswordAgeDays } }; Descending = $true })
    Write-Verbose ("Collected {0} credential record(s). No passwords are included in the output." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    if ($connection) { Disconnect-VcfSddcManagerServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue }
}
