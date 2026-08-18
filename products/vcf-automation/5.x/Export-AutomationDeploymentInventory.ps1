<#
.SYNOPSIS
    Lists every deployment with its owner, project, blueprint, lease expiry, resource count and cost.

.DESCRIPTION
    Returns one row per deployment carrying the project and blueprint it came from, who owns it,
    when it was created and last updated, its lease expiry and days remaining, the number and
    type of resources inside it, and the cost where pricing is configured.

    This is the table every showback conversation and every cleanup exercise starts from, and
    the deployments view cannot produce it. The lease column is the useful one: deployments with
    no expiry are the ones that live forever.

    Pain area addressed: #10 Cross-domain inventory; #5 Orphaned and zombie assets.

.PARAMETER Server
    FQDN or IP address of the VCF Automation appliance.

.PARAMETER Credential
    Credential used to authenticate to the VCF Automation API.

.PARAMETER ProjectName
    Limit to deployments in these projects.

.PARAMETER OwnedBy
    Limit to deployments owned by these users.

.PARAMETER NoLeaseOnly
    Return only deployments with no lease expiry set - the ones that never go away.

.PARAMETER PageSize
    How many deployments to request per call. Defaults to 200.

.PARAMETER IgnoreInvalidCertificate
    Accept an untrusted or self-signed certificate on the target endpoint. Use only in lab
    environments.

.PARAMETER OutputPath
    Path of the file to write. When omitted the records are only returned on the pipeline and
    nothing is written to disk.

.PARAMETER Format
    Output file format. CSV is the flat table, JSON carries the export envelope that the
    matching import script validates, HTML is a styled table for sharing.

.EXAMPLE
    PS> ./Export-AutomationDeploymentInventory.ps1 -Server automation.example.local -Credential $cred -NoLeaseOnly

    Finds deployments with no expiry date at all.

.EXAMPLE
    PS> ./Export-AutomationDeploymentInventory.ps1 -Server automation.example.local -Credential $cred | Group-Object OwnedBy | Sort-Object Count -Descending

    Ranks owners by how many deployments each holds.

.NOTES
    Author        : Sampath
    Product       : Aria Automation (VCF 5.x)
    Target        : VMware Cloud Foundation 5.x
    Modules       : None (uses Invoke-RestMethod)
    Behaviour     : Read-only. Collects data and optionally writes it to disk.
    Standalone    : Yes. This script does not dot-source or import any other file
                    in this repository and can be copied out on its own.
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Server,
    [Parameter(Mandatory)] [System.Management.Automation.PSCredential]$Credential,
    [Parameter()] [string[]]$ProjectName,
    [Parameter()] [string[]]$OwnedBy,
    [Parameter()] [switch]$NoLeaseOnly,
    [Parameter()] [int]$PageSize = 200,
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
    Schema        = 'automation.deployment-inventory'
    SchemaVersion = '1.0'
    Product       = 'vcf-automation'
    VcfVersion    = '5.x'
    Server        = $Server
}

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
    $authBody = @{ username = $Credential.UserName; password = $Credential.GetNetworkCredential().Password } | ConvertTo-Json
    $refresh = Invoke-RestMethod @restCommon -Method Post -Uri "$baseUri/csp/gateway/am/api/login?access_token" -Body $authBody
    $exchange = @{ refreshToken = $refresh.refresh_token } | ConvertTo-Json
    $access = Invoke-RestMethod @restCommon -Method Post -Uri "$baseUri/iaas/api/login" -Body $exchange
    $headers = @{ Accept = 'application/json'; Authorization = "Bearer $($access.token)" }
    Write-Verbose "Acquired a VCF Automation access token from $Server"

    $records = @()

    $skip = 0
    do {
        $uri = '{0}/deployment/api/deployments?expand=resources&expandLastRequest=false&size={1}&page={2}' -f $baseUri, $PageSize, ($skip / $PageSize)
        $response = Invoke-RestMethod @restCommon -Method Get -Uri $uri -Headers $headers
        $page = @($response.content)

        foreach ($deployment in $page) {
            if ($ProjectName -and $deployment.project.name -notin $ProjectName) { continue }
            if ($OwnedBy -and $deployment.ownedBy -notin $OwnedBy) { continue }

            $leaseExpiry = $null
            if ($deployment.expense.lastUpdatedTime) { $leaseExpiry = $null }
            if ($deployment.leaseExpireAt) {
                try { $leaseExpiry = [datetime]$deployment.leaseExpireAt } catch { $leaseExpiry = $null }
            }

            if ($NoLeaseOnly -and $leaseExpiry) { continue }

            $daysRemaining = $null
            if ($leaseExpiry) { $daysRemaining = [int][math]::Floor(($leaseExpiry - (Get-Date)).TotalDays) }

            $resources = @($deployment.resources)
            $resourceTypes = @($resources.type | Sort-Object -Unique)

            $records += [pscustomobject]@{
                Name            = $deployment.name
                DeploymentId    = $deployment.id
                Project         = $deployment.project.name
                Blueprint       = $deployment.blueprintId
                BlueprintVersion = $deployment.blueprintVersion
                OwnedBy         = $deployment.ownedBy
                Status          = $deployment.status
                CreatedAt       = $deployment.createdAt
                LastUpdated     = $deployment.lastUpdatedAt
                LeaseExpiry     = if ($leaseExpiry) { $leaseExpiry.ToString('u') } else { '' }
                LeaseDaysLeft   = $daysRemaining
                ResourceCount   = $resources.Count
                ResourceTypes   = ($resourceTypes -join '; ')
                TotalCost       = $deployment.expense.totalExpense
                CostCurrency    = $deployment.expense.unit
            }
        }

        $skip += $PageSize
        Write-Verbose ("  read {0} deployment(s) so far" -f $records.Count)
    } while ($page.Count -eq $PageSize)

    $records = @($records | Sort-Object Project, Name)
    Write-Verbose ("Collected {0} deployment record(s)." -f $records.Count)

    if ($OutputPath) {
        Out-ResultFile -Record $records -Path $OutputPath -Format $Format -Meta $exportMeta
    }

    $records
}
finally {
    $headers = $null
}
