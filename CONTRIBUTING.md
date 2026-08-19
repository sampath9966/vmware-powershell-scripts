# Contributing

Every script in this repository follows the same contract. It is short, and it is the
reason a script from one product folder behaves like a script from any other.

## The one rule that shapes everything else

**A script must run standalone.** No shared module, no dot-sourcing, no assumption about
where it sits in the repository. Copy a single `.ps1` onto a jump box with PowerCLI
installed and it works.

That means helper functions are repeated inside each script that needs them. This is
deliberate. A shared helper module would be better engineering and worse for the people
who actually use this - who copy one file into a runbook, paste it into a ticket, or hand
it to someone who has never seen the repository.

## Layout

```
products/<product>/<version>/<Verb>-<Product><Noun>.ps1
```

`<version>` is `5.x` or `9.x`. A use case that exists in both generations gets a script in
both folders, even when the body is identical - the reader should never have to work out
whether the 5.x folder's absence means "same as 9.x" or "not supported".

## Verbs

| Verb | Meaning | Changes anything? |
|---|---|---|
| `Export-` | Reads, and writes the round-trip envelope | No |
| `Get-…Report` | Reads, no import counterpart exists | No |
| `Import-` | Consumes an `Export-` file and applies it | Yes |
| `Invoke-` / `Set-` | Remediates, usually from an export file | Yes |

## Every script

1. Comment-based help with `.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER` for every parameter,
   at least one `.EXAMPLE`, and `.NOTES` carrying `Author`, the target VCF version and the
   pain area it addresses.
2. `#Requires -Version 5.1` and a `#Requires -Modules` line per module it needs.
   PowerShell 5.1 is the floor - no ternaries, no null-coalescing, no `-SkipCertificateCheck`
   without a version guard.
3. `[CmdletBinding()]` and a `param()` block. `-Server` and `-Credential` are always the
   first two parameters, and `-Credential` is always `[PSCredential]`.
4. Connect, work inside `try`, disconnect inside `finally`. Always.
5. `Write-Verbose` for progress. `Write-Warning` for something the operator should see but
   which does not stop the run. A terminating `throw` when continuing would be wrong.
6. No hard-coded hostnames, no plaintext passwords, no silently disabling certificate
   validation - `-IgnoreInvalidCertificate` is opt-in, warns when used, and is documented
   as lab-only.
7. Secrets are never written to output. Password and certificate scripts export metadata;
   where a value has to be represented, it is replaced with a marker.

## Read scripts

Build `$records` as an array of `[PSCustomObject]`, emit it to the pipeline, and write a
file only when `-OutputPath` is given. `-Format CSV|JSON|HTML` selects the shape.

JSON output uses the envelope, which is what makes the round trip possible:

```json
{ "schema": "vcf.sddc.certificate-inventory", "schemaVersion": "1.0",
  "product": "sddc-manager", "vcfVersion": "5.x",
  "exportedOn": "2026-01-01T00:00:00.0000000Z", "sourceServer": "sddc.example.local",
  "recordCount": 42, "data": [ ... ] }
```

Pick the `schema` value as `<product>.<thing>` and keep it stable - it is the contract
between the two halves of a round trip.

## Write scripts

1. `[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]`.
2. Read `-InputPath` through the envelope validator. Refuse a mismatched `schema` or
   `product`; warn on a mismatched `vcfVersion`.
3. Build `$plan` - one object per item with an `Action` of `Create`, `Update`, `Remove` or
   `Match`. Everything already correct must come back as `Match`, so re-running is safe.
4. `-DiffOnly` returns the plan and changes nothing. This is the intended first run and the
   examples in the help should show it first.
5. Wrap every individual change in `$PSCmdlet.ShouldProcess()` with a target string that
   names the thing precisely enough to decide from.
6. Re-verify against live state before anything destructive. A file exported last week must
   not be able to delete something created yesterday.
7. Never delete as a side effect of a sync. Removing things is its own script with its own
   explicit parameter.

## Connection scoping

Any script that opens its own connection **must** pin every call to it:

```powershell
$connection = Connect-VIServer -Server $Server -Credential $Credential -ErrorAction Stop

$PSDefaultParameterValues = $PSDefaultParameterValues.Clone()
$PSDefaultParameterValues['*:Server'] = $connection
```

This is not optional and it is not cosmetic. PowerCLI cmdlets act on *every*
connected server. With two vCenters connected, `Get-VM` returns both inventories
merged with no indication which is which, and `Get-VIPrivilege` returns every
privilege twice - which is how a role import once failed with
*"The specified privileges are from a different server"* after reporting
`170 of 85 privileges resolved`.

Two details matter:

- **Clone first.** `$PSDefaultParameterValues['x'] = $y` mutates the hashtable
  inherited from the caller, so the setting would outlive the script and change
  the behaviour of everything the operator runs afterwards. Assigning a clone
  keeps it script-scoped.
- **One wildcard key only.** If `*:Server` and `Get-Something:Server` are both
  set, PowerShell warns and ignores *both*. Where a call needs a different
  connection - `Get-CisService` wants the CIS one, not the vSphere one - pass
  `-Server` explicitly at the call site, which always wins over a default.

## Validate in the plan, not in the apply

Anything that can make a change fail should be checked while `$plan` is being
built, so `-DiffOnly` surfaces it. A check that only runs during apply gives a
clean dry run followed by a failed real one, which is worse than no dry run.

The role import learned this the hard way: it verified that privileges existed
only as it created each role, so `-DiffOnly` looked perfect and the real run
died on the first role.

## Before opening a pull request

```powershell
Install-Module PSScriptAnalyzer -Scope CurrentUser

# One command. This is exactly what CI runs.
./tools/Invoke-RepositoryCheck.ps1
```

It checks parsing, analyzer findings, PowerShell 7 syntax in scripts declaring
5.1, comment-based help, authorship, `ShouldProcess` and `-DiffOnly` on write
scripts, connection scoping, standalone-ness, README cross-references, and
attribution markers. Every one of those rules exists because something went
wrong once; adding a rule when you fix a new class of bug is the point.

Also confirm your help renders:

```powershell
Get-Help ./products/<product>/<version>/<YourScript>.ps1 -Full
```

Watch for the two things that catch people out: PowerShell automatic variable names
(`$switch`, `$event`, `$args`, `$profile`, `$input`, `$matches`, `$host`) and here-strings,
whose closing `'@` must sit at column zero and therefore cannot be indented inside a
`try` block.

Add the script to its version folder `README.md` table, and the use case to the product
`README.md` table.

## Testing against a real environment

None of this is executed against live VCF in CI - there is nothing to execute it against.
If you have run a script for real, say so in the pull request, and say which version and
build you ran it on. That is worth more than any amount of static checking.
