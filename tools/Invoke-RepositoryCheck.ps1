<#
.SYNOPSIS
    Runs every structural and safety check this repository relies on.

.DESCRIPTION
    The scripts here cannot be executed against a live VMware Cloud Foundation
    instance in CI, so correctness rests on static guarantees instead. This is the
    single place those guarantees are defined, and CI runs exactly this file - so a
    check can never drift between "what CI does" and "what a contributor can run".

    Each rule exists because something actually went wrong once:

      Parse              - a here-string terminator indented inside a try block.
      Analyzer           - assignments to automatic variables ($switch, $args).
      DownlevelSyntax    - PowerShell 7 ternaries in scripts declaring 5.1.
      Help               - scripts shipping without usable comment-based help.
      Authorship         - the .NOTES author block going missing.
      WriteSafety        - a write script losing -DiffOnly or ShouldProcess.
      ConnectionScoping  - PowerCLI cmdlets acting on every connected server at
                           once, silently mixing two vCenters into one export.
      Standalone         - a script quietly growing a dependency on another file.
      CrossReference     - a script existing but listed in no README.
      Attribution        - generated-by markers appearing in tracked content.

.PARAMETER Path
    Repository root to check. Defaults to the parent of this script's folder.

.PARAMETER SkipAnalyzer
    Skip PSScriptAnalyzer, for when the module is not installed.

.EXAMPLE
    PS> ./tools/Invoke-RepositoryCheck.ps1

    Runs every check and exits non-zero if any fails.

.NOTES
    Author        : Sampath
    Behaviour     : Read-only. Inspects files, changes nothing.
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter()][string]$Path,
    [Parameter()][switch]$SkipAnalyzer
)

$ErrorActionPreference = 'Stop'

if (-not $Path) { $Path = Split-Path -Parent $PSScriptRoot }
$productRoot = Join-Path $Path 'products'

$failures = [System.Collections.Generic.List[string]]::new()
function Add-Failure { param([string]$Rule, [string]$Detail) $failures.Add(("{0}: {1}" -f $Rule, $Detail)) }

$scripts = @(Get-ChildItem -LiteralPath $productRoot -Recurse -Filter *.ps1)
Write-Output ("Checking {0} script(s) under {1}" -f $scripts.Count, $productRoot)

# --------------------------------------------------------------- parse + syntax
foreach ($script in $scripts) {
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$null, [ref]$errors)

    if ($errors -and $errors.Count) {
        Add-Failure 'Parse' ("{0}:{1} {2}" -f $script.Name, $errors[0].Extent.StartLineNumber, $errors[0].Message)
        continue
    }

    # Scripts declare 5.1 as the floor, so PowerShell 7 only syntax must not appear.
    # Detected through the AST rather than by regex, which cannot tell a ternary from
    # a question mark inside a string.
    $downlevel = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.TernaryExpressionAst] -or
        ($node -is [System.Management.Automation.Language.BinaryExpressionAst] -and
            $node.Operator -in @('QuestionQuestion', 'QuestionDot'))
    }, $true)

    foreach ($node in $downlevel) {
        Add-Failure 'DownlevelSyntax' ("{0}:{1} uses PowerShell 7 only syntax but declares #Requires -Version 5.1" -f `
            $script.Name, $node.Extent.StartLineNumber)
    }
}

# ------------------------------------------------------------------- per script
foreach ($script in $scripts) {
    $text = Get-Content -LiteralPath $script.FullName -Raw

    foreach ($section in @('.SYNOPSIS', '.DESCRIPTION', '.EXAMPLE', '.NOTES')) {
        if ($text -notmatch [regex]::Escape($section)) {
            Add-Failure 'Help' ("{0} has no {1}" -f $script.Name, $section)
        }
    }

    if ($text -notmatch 'Author\s*:\s*Sampath') {
        Add-Failure 'Authorship' ("{0} has no author in its .NOTES block" -f $script.Name)
    }

    if ($text -notmatch '#Requires -Version 5\.1') {
        Add-Failure 'Help' ("{0} does not declare #Requires -Version 5.1" -f $script.Name)
    }

    if ($text -match '(?m)^\s*\.\s+["'']?\$PSScriptRoot' -or $text -match '(?m)^\s*Import-Module\s+\.') {
        Add-Failure 'Standalone' ("{0} loads another file from this repository" -f $script.Name)
    }

    if ($script.Name -match '^(Import|Invoke|Set)-') {
        if ($text -notmatch 'SupportsShouldProcess') {
            Add-Failure 'WriteSafety' ("{0} changes state but does not declare SupportsShouldProcess" -f $script.Name)
        }
        if ($text -notmatch '\$PSCmdlet\.ShouldProcess') {
            Add-Failure 'WriteSafety' ("{0} declares SupportsShouldProcess but never calls it" -f $script.Name)
        }
        if ($text -notmatch '\$DiffOnly') {
            Add-Failure 'WriteSafety' ("{0} does not honour -DiffOnly" -f $script.Name)
        }
    }

    # A script that opens its own cmdlet-based connection must pin every call to it.
    # This is the check that would have caught two connected vCenters being merged
    # into a single export, and privileges being resolved twice from two servers.
    if ($text -match '(?m)^\s*\$connection = Connect-') {
        if ($text -notmatch [regex]::Escape("PSDefaultParameterValues['*:Server'] = `$connection")) {
            Add-Failure 'ConnectionScoping' ("{0} opens a connection but does not scope its cmdlets to it" -f $script.Name)
        }
        if ($text -notmatch [regex]::Escape('$PSDefaultParameterValues.Clone()')) {
            Add-Failure 'ConnectionScoping' ("{0} sets parameter defaults without cloning, which leaks into the caller" -f $script.Name)
        }
    }

    $readme = Join-Path $script.DirectoryName 'README.md'
    if (-not (Test-Path -LiteralPath $readme)) {
        Add-Failure 'CrossReference' ("{0} has no README" -f $script.DirectoryName)
    }
    elseif ((Get-Content -LiteralPath $readme -Raw) -notmatch [regex]::Escape($script.BaseName)) {
        Add-Failure 'CrossReference' ("{0} is not listed in its folder README" -f $script.Name)
    }
}

# -------------------------------------------------------------------- analyzer
if (-not $SkipAnalyzer) {
    if (Get-Module -ListAvailable -Name PSScriptAnalyzer) {
        Import-Module PSScriptAnalyzer
        foreach ($finding in (Invoke-ScriptAnalyzer -Path $productRoot -Recurse -Severity Error, Warning)) {
            Add-Failure 'Analyzer' ("{0}:{1} {2}" -f (Split-Path $finding.ScriptName -Leaf), $finding.Line, $finding.RuleName)
        }
        foreach ($finding in (Invoke-ScriptAnalyzer -Path $PSCommandPath -Severity Error, Warning)) {
            Add-Failure 'Analyzer' ("{0}:{1} {2}" -f (Split-Path $finding.ScriptName -Leaf), $finding.Line, $finding.RuleName)
        }
    }
    else {
        Write-Warning 'PSScriptAnalyzer is not installed; that check was skipped.'
    }
}

# ----------------------------------------------------------------- attribution
foreach ($file in (Get-ChildItem -LiteralPath $Path -Recurse -File -Include '*.ps1', '*.md', '*.yml' |
        Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' -and $_.FullName -ne $PSCommandPath })) {
    if ((Get-Content -LiteralPath $file.FullName -Raw) -match 'generated by|co-authored-by') {
        Add-Failure 'Attribution' ("{0} carries a generated-by marker" -f $file.Name)
    }
}

# --------------------------------------------------------------------- summary
Write-Output ''
if ($failures.Count -eq 0) {
    Write-Output 'All checks passed.'
    exit 0
}

Write-Output ("{0} failure(s):" -f $failures.Count)
foreach ($failure in ($failures | Group-Object { ($_ -split ':')[0] })) {
    Write-Output ("  [{0}] {1}" -f $failure.Name, $failure.Count)
    foreach ($detail in ($failure.Group | Select-Object -First 10)) { Write-Output ("      {0}" -f $detail) }
}
exit 1
