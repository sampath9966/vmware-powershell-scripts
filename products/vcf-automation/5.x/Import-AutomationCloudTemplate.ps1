<#
.SYNOPSIS
    Creates cloud templates from an export in the matching project, and optionally releases a version.

.DESCRIPTION
    Creates each template that does not already exist in the target, in the project of the same
    name, using the YAML carried in the export. Templates that exist come back as Match unless
    -UpdateExisting is given, in which case their content is replaced.

    The target project has to exist - templates are scoped to a project and creating one
    implicitly would put it somewhere arbitrary. A template whose project is missing is reported
    and skipped; run the project import first.

    Pain area addressed: #16 Config portability between environments.

.PARAMETER Server
    FQDN or IP address of the VCF Automation appliance.

.PARAMETER Credential
    Credential used to authenticate to the VCF Automation API.

.PARAMETER InputPath
    Path to the .json (preferred) or .csv file written by the matching Export-* script. The
    envelope is validated before anything is changed.

.PARAMETER TemplateName
    Limit the import to these template names.

.PARAMETER TargetProject
    Put every imported template in this project, overriding the project recorded in the file.

.PARAMETER UpdateExisting
    Replace the content of templates that already exist.

.PARAMETER ReleaseVersion
    Create and release a version with this name after importing. Omit to leave templates in
    draft.

.PARAMETER IgnoreInvalidCertificate
    Accept an untrusted or self-signed certificate on the target endpoint. Use only in lab
    environments.

.PARAMETER DiffOnly
    Show the planned changes and exit without applying any of them. Use this first, every time.

.EXAMPLE
    PS> ./Import-AutomationCloudTemplate.ps1 -Server automation2.example.local -Credential $cred -InputPath ./templates.json -DiffOnly

    Shows which templates are missing from the target.

.NOTES
    Author        : Sampath
    Product       : Aria Automation (VCF 5.x)
    Target        : VMware Cloud Foundation 5.x
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
    [Parameter()] [string[]]$TemplateName,
    [Parameter()] [string]$TargetProject,
    [Parameter()] [switch]$UpdateExisting,
    [Parameter()] [string]$ReleaseVersion,
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

function Compare-DesiredState {
    <#
        Joins the desired records from the input file against what the target
        currently has, and labels each one Create, Update or Match so the plan can
        be reviewed before a single change is committed.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowEmptyCollection()][object[]]$Current,
        [Parameter()][AllowEmptyCollection()][object[]]$Desired,
        [Parameter(Mandatory)][string]$KeyProperty,
        [Parameter()][string[]]$CompareProperty
    )

    $index = @{}
    foreach ($item in @($Current)) {
        $key = [string]$item.$KeyProperty
        if ($key) { $index[$key] = $item }
    }

    foreach ($item in @($Desired)) {
        $key = [string]$item.$KeyProperty
        if (-not $key) {
            Write-Warning "Skipping a desired record with no '$KeyProperty' value."
            continue
        }

        $existing = $index[$key]
        $changed = @()

        if ($null -eq $existing) {
            $action = 'Create'
        }
        else {
            $properties = if ($CompareProperty) { $CompareProperty } else { @($item.PSObject.Properties.Name) }
            foreach ($property in $properties) {
                if ($property -eq $KeyProperty) { continue }
                $left  = [string]$existing.$property
                $right = [string]$item.$property
                if ($left -ne $right) { $changed += $property }
            }
            $action = if ($changed.Count -gt 0) { 'Update' } else { 'Match' }
        }

        [pscustomobject]@{
            Key             = $key
            Action          = $action
            ChangedProperty = ($changed -join ', ')
            Desired         = $item
            Current         = $existing
        }
    }
}

$expectedSchema     = 'automation.cloud-template'
$expectedProduct    = 'vcf-automation'
$expectedVcfVersion = '5.x'

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

    $desired = Read-ExportFile -Path $InputPath -ExpectedSchema $expectedSchema `
        -ExpectedProduct $expectedProduct -ExpectedVcfVersion $expectedVcfVersion

    if ($TemplateName) { $desired = @($desired | Where-Object { $_.Name -in $TemplateName }) }

    $projectIdByName = @{}
    $projectResponse = Invoke-RestMethod @restCommon -Method Get -Uri "$baseUri/project-service/api/projects" -Headers $headers
    foreach ($project in @($projectResponse.content)) { $projectIdByName[$project.name] = $project.id }

    $response = Invoke-RestMethod @restCommon -Method Get -Uri "$baseUri/blueprint/api/blueprints?`$top=500" -Headers $headers
    $current = foreach ($template in @($response.content)) {
        [pscustomobject]@{ Name = $template.name; Project = $template.projectName; TemplateId = $template.id }
    }

    Write-Verbose ("Input lists {0} template(s); target has {1} and {2} project(s)." -f `
        @($desired).Count, @($current).Count, $projectIdByName.Count)

    $plan = Compare-DesiredState -Current @($current) -Desired @($desired) `
        -KeyProperty 'Name' -CompareProperty @('Project')

    if (-not $UpdateExisting) {
        foreach ($item in $plan) { if ($item.Action -eq 'Update') { $item.Action = 'Match' } }
    }

    foreach ($item in $plan) {
        $projectName = if ($TargetProject) { $TargetProject } else { $item.Desired.Project }
        $item | Add-Member -NotePropertyName ProjectName -NotePropertyValue $projectName -Force
        $item | Add-Member -NotePropertyName ProjectId -NotePropertyValue $projectIdByName[$projectName] -Force

        if ($item.Action -ne 'Match' -and -not $item.ProjectId) {
            Write-Warning ("Project '{0}' does not exist in the target. '{1}' will be skipped." -f $projectName, $item.Key)
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
        $row = $item.Desired

        if (-not $item.ProjectId) {
            [pscustomobject]@{ Template = $item.Key; Status = 'SkippedMissingProject' }
            continue
        }

        if (-not $row.Content) {
            Write-Warning "Template '$($item.Key)' has no YAML content in the export. Skipping."
            [pscustomobject]@{ Template = $item.Key; Status = 'SkippedNoContent' }
            continue
        }

        if (-not $PSCmdlet.ShouldProcess("cloud template '$($item.Key)' in project '$($item.ProjectName)'", $item.Action)) { continue }

        try {
            $payload = @{
                name        = $row.Name
                description = $row.Description
                projectId   = $item.ProjectId
                content     = $row.Content
            } | ConvertTo-Json -Depth 8

            $templateId = $null
            if ($item.Action -eq 'Create') {
                $created = Invoke-RestMethod @restCommon -Method Post -Uri "$baseUri/blueprint/api/blueprints" -Headers $headers -Body $payload
                $templateId = $created.id
            }
            else {
                $templateId = $item.Current.TemplateId
                Invoke-RestMethod @restCommon -Method Put `
                    -Uri ('{0}/blueprint/api/blueprints/{1}' -f $baseUri, $templateId) -Headers $headers -Body $payload | Out-Null
            }

            $releasedAs = ''
            if ($ReleaseVersion -and $templateId) {
                $versionPayload = @{ version = $ReleaseVersion; release = $true } | ConvertTo-Json
                Invoke-RestMethod @restCommon -Method Post `
                    -Uri ('{0}/blueprint/api/blueprints/{1}/versions' -f $baseUri, $templateId) `
                    -Headers $headers -Body $versionPayload | Out-Null
                $releasedAs = $ReleaseVersion
            }

            [pscustomobject]@{ Template = $item.Key; Project = $item.ProjectName; Action = $item.Action; Released = $releasedAs; Status = 'Applied' }
        }
        catch {
            Write-Warning ("Could not apply template '{0}': {1}" -f $item.Key, $_.Exception.Message)
            [pscustomobject]@{ Template = $item.Key; Project = $item.ProjectName; Action = $item.Action; Released = ''; Status = 'Failed' }
        }
    }
}
finally {
    $headers = $null
}
