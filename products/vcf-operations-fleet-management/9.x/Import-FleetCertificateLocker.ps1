<#
.SYNOPSIS
    Imports PEM certificate files into the locker for the aliases listed in a locker export.

.DESCRIPTION
    Reads a locker export to work out which aliases need replacing, then loads the matching PEM
    file for each from -CertificateDirectory. Files are matched to aliases by filename, so
    'web-tier.pem' loads against the 'web-tier' alias.

    The private key is read from the matching .key file only if one is present next to the
    certificate, and it is never written to the export or the log. Aliases with no matching file
    on disk are reported and skipped.

    Pain area addressed: #1 Certificate expiry across the stack.

.PARAMETER Server
    FQDN or IP address of the VCF Operations fleet management (Aria Suite Lifecycle) appliance.

.PARAMETER Credential
    Credential used to authenticate to the fleet management API.

.PARAMETER InputPath
    Path to the .json (preferred) or .csv file written by the matching Export-* script. The
    envelope is validated before anything is changed.

.PARAMETER CertificateDirectory
    Directory holding the renewed .pem certificate files, named after the locker alias they
    replace.

.PARAMETER ExpiringInDays
    Only replace certificates expiring within this many days. Defaults to 30.

.PARAMETER IgnoreInvalidCertificate
    Accept an untrusted or self-signed certificate on the target endpoint. Use only in lab
    environments.

.PARAMETER DiffOnly
    Show the planned changes and exit without applying any of them. Use this first, every time.

.EXAMPLE
    PS> ./Import-FleetCertificateLocker.ps1 -Server lcm.example.local -Credential $cred -InputPath ./certs.json -CertificateDirectory ./renewed -DiffOnly

    Shows which aliases would be replaced and which have no file on disk.

.NOTES
    Author        : Sampath
    Product       : VCF Operations fleet management (VCF 9.x)
    Target        : VMware Cloud Foundation 9.x
    Modules       : None (uses Invoke-RestMethod)
    Behaviour     : Changes the target. Supports -WhatIf, -Confirm and -DiffOnly.
    Standalone    : Yes. This script does not dot-source or import any other file
                    in this repository and can be copied out on its own.
#>

#Requires -Version 5.1

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Server,
    [Parameter(Mandatory)] [System.Management.Automation.PSCredential]$Credential,
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$InputPath,
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$CertificateDirectory,
    [Parameter()] [int]$ExpiringInDays = 30,
    [Parameter()] [switch]$IgnoreInvalidCertificate,
    [Parameter()] [switch]$DiffOnly
)

$ErrorActionPreference = 'Stop'

function Read-ExportFile {
    <#
        Loads a .json export envelope (or a flat .csv) produced by the matching
        Export-* script and refuses to continue if it describes something else.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedSchema,
        [Parameter(Mandatory)][string]$ExpectedProduct,
        [Parameter(Mandatory)][string]$ExpectedVcfVersion
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Input file not found: $Path"
    }

    switch ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        '.json' {
            $document = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
            $names = @($document.PSObject.Properties.Name)
            if ($names -notcontains 'schema') {
                Write-Verbose 'Input has no export envelope; treating the whole document as data.'
                return @($document)
            }
            if ($document.schema -ne $ExpectedSchema) {
                throw ("Schema mismatch. File declares '{0}' but this script expects '{1}'." -f $document.schema, $ExpectedSchema)
            }
            if ($document.product -and $document.product -ne $ExpectedProduct) {
                throw ("Product mismatch. File was exported from '{0}' but this script targets '{1}'." -f $document.product, $ExpectedProduct)
            }
            if ($document.vcfVersion -and $document.vcfVersion -ne $ExpectedVcfVersion) {
                Write-Warning ("File was exported from VCF {0} but this script targets VCF {1}. Review the diff carefully." -f $document.vcfVersion, $ExpectedVcfVersion)
            }
            return @($document.data)
        }
        '.csv' {
            Write-Verbose 'CSV input carries no envelope; schema and version cannot be validated.'
            return @(Import-Csv -LiteralPath $Path)
        }
        default {
            throw "Unsupported input format. Provide the .json or .csv file written by the matching Export-* script."
        }
    }
}


$expectedSchema     = 'fleet.certificate-locker'
$expectedProduct    = 'vcf-operations-fleet-management'
$expectedVcfVersion = '9.x'

$headers = $null
try {
    $restCommon = @{ ContentType = 'application/json' }

    if ($PSVersionTable.PSVersion.Major -lt 6) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    }

    if ($IgnoreInvalidCertificate) {
        if ($PSVersionTable.PSVersion.Major -ge 6) {
            $restCommon['SkipCertificateCheck'] = $true
        }
        else {
            Write-Warning 'Certificate validation is disabled for this session. Use this only in lab environments.'
            [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        }
    }

    $baseUri = "https://$Server"
    $pair = '{0}:{1}' -f $Credential.UserName, $Credential.GetNetworkCredential().Password
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair))
    $headers = @{ Accept = 'application/json'; Authorization = "Basic $encoded" }
    Write-Verbose "Prepared basic authentication for $Server"

    if (-not (Test-Path -LiteralPath $CertificateDirectory)) {
        throw "Certificate directory not found: $CertificateDirectory"
    }

    $desired = Read-ExportFile -Path $InputPath -ExpectedSchema $expectedSchema `
        -ExpectedProduct $expectedProduct -ExpectedVcfVersion $expectedVcfVersion

    Write-Verbose ("Input lists {0} certificate record(s)." -f @($desired).Count)

    $plan = foreach ($record in @($desired)) {
        $days = $null
        if ($null -ne $record.DaysRemaining -and $record.DaysRemaining -ne '') { $days = [int]$record.DaysRemaining }
        if ($null -eq $days -or $days -gt $ExpiringInDays) { continue }

        $pemPath = Join-Path $CertificateDirectory ($record.Alias + '.pem')
        if (-not (Test-Path -LiteralPath $pemPath)) {
            Write-Warning "No file '$($record.Alias).pem' in $CertificateDirectory. Skipping that alias."
            continue
        }

        [pscustomobject]@{
            Key             = $record.Alias
            Action          = 'Update'
            ChangedProperty = 'certificate'
            Alias           = $record.Alias
            DaysRemaining   = $days
            PemPath         = $pemPath
            KeyPath         = Join-Path $CertificateDirectory ($record.Alias + '.key')
            Desired         = $record
            Current         = $null
        }
    }

    $actionable = @($plan | Where-Object { $_.Action -ne 'Match' })
    Write-Verbose ("Plan: {0} change(s), {1} already in the desired state." -f $actionable.Count, (@($plan).Count - $actionable.Count))

    if ($DiffOnly) {
        Write-Verbose '-DiffOnly was specified. Nothing was changed.'
        return $plan
    }

    if ($actionable.Count -eq 0) {
        Write-Verbose 'Everything already matches the desired state. Nothing to do.'
        return $plan
    }
    foreach ($item in $actionable) {
        if (-not $PSCmdlet.ShouldProcess("locker alias '$($item.Alias)'", 'Import renewed certificate')) { continue }

        try {
            $payload = @{
                alias           = $item.Alias
                certificateChain = (Get-Content -LiteralPath $item.PemPath -Raw)
            }
            if (Test-Path -LiteralPath $item.KeyPath) {
                $payload['privateKey'] = (Get-Content -LiteralPath $item.KeyPath -Raw)
            }

            Invoke-RestMethod @restCommon -Method Post -Uri "$baseUri/lcm/locker/api/v2/certificates/import" `
                -Headers $headers -Body ($payload | ConvertTo-Json -Depth 6) | Out-Null

            [pscustomobject]@{ Alias = $item.Alias; DaysRemaining = $item.DaysRemaining; Status = 'Imported' }
        }
        catch {
            Write-Warning ("Could not import '{0}': {1}" -f $item.Alias, $_.Exception.Message)
            [pscustomobject]@{ Alias = $item.Alias; DaysRemaining = $item.DaysRemaining; Status = 'Failed' }
        }
    }
}
finally {
    $headers = $null
}
