# Workspace ONE Access - VCF 5.x

PowerCLI scripts for Workspace ONE Access as shipped in VMware Cloud Foundation 5.x.

Every script is standalone: copy any single `.ps1` out of this folder and it runs on
its own. Nothing here dot-sources a shared helper.

| Script | Use case | Mode | Pain area | Modules |
|---|---|---|---|---|
| [`Export-IdentityProvider.ps1`](Export-IdentityProvider.ps1) | Identity providers and the authentication methods each offers | Read | #16 | `(REST via Invoke-RestMethod)` |
| [`Export-IdentityDirectoryConfig.ps1`](Export-IdentityDirectoryConfig.ps1) | Directory connections and their sync configuration | Read | #16, #9 | `(REST via Invoke-RestMethod)` |
| [`Export-IdentitySyncStatus.ps1`](Export-IdentitySyncStatus.ps1) | Directory sync drift - what stopped syncing and when | Read | #9 | `(REST via Invoke-RestMethod)` |
| [`Export-IdentityAccessPolicy.ps1`](Export-IdentityAccessPolicy.ps1) | Access policies and their authentication rules | Read | #16 | `(REST via Invoke-RestMethod)` |
| [`Import-IdentityAccessPolicy.ps1`](Import-IdentityAccessPolicy.ps1) | Replay an access policy into another instance | Write | #16 | `(REST via Invoke-RestMethod)` |
| [`Export-IdentityRoleAssignment.ps1`](Export-IdentityRoleAssignment.ps1) | Who holds an administrative role | Read | #13 | `(REST via Invoke-RestMethod)` |
| [`Export-IdentityAuditEvent.ps1`](Export-IdentityAuditEvent.ps1) | Login and administrative audit trail | Read | #13 | `(REST via Invoke-RestMethod)` |

## Export / import round trips

These pairs share an export envelope. The export writes it, the write-side script
validates it before changing anything, so the two always agree on the shape.

| Envelope schema | Export | Applies it |
|---|---|---|
| `identity.access-policy` | [`Export-IdentityAccessPolicy.ps1`](Export-IdentityAccessPolicy.ps1) | [`Import-IdentityAccessPolicy.ps1`](Import-IdentityAccessPolicy.ps1) |

## Safety

Scripts marked **Write** change the target. They all support `-DiffOnly` to print the
plan and stop, and `-WhatIf` / `-Confirm` through `SupportsShouldProcess`. Run any of
them with `-DiffOnly` first.

Back to [Workspace ONE Access](../README.md) | [repository index](../../../README.md)
