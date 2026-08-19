# Aria Suite Lifecycle - VCF 5.x

PowerCLI scripts for Aria Suite Lifecycle as shipped in VMware Cloud Foundation 5.x.

Every script is standalone: copy any single `.ps1` out of this folder and it runs on
its own. Nothing here dot-sources a shared helper.

| Script | Use case | Mode | Pain area | Modules |
|---|---|---|---|---|
| [`Export-FleetEnvironmentInventory.ps1`](Export-FleetEnvironmentInventory.ps1) | Which product is on which version, in which environment | Read | #3 | `(REST via Invoke-RestMethod)` |
| [`Export-FleetCertificateLocker.ps1`](Export-FleetCertificateLocker.ps1) | Certificate locker contents and expiry | Read | #1 | `(REST via Invoke-RestMethod)` |
| [`Import-FleetCertificateLocker.ps1`](Import-FleetCertificateLocker.ps1) | Load renewed certificates into the locker | Write | #1 | `(REST via Invoke-RestMethod)` |
| [`Export-FleetPasswordLocker.ps1`](Export-FleetPasswordLocker.ps1) | Password locker metadata without the secrets | Read | #2 | `(REST via Invoke-RestMethod)` |
| [`Export-FleetProductBinary.ps1`](Export-FleetProductBinary.ps1) | Which install and upgrade binaries are actually staged | Read | #12 | `(REST via Invoke-RestMethod)` |
| [`Export-FleetRequestHistory.ps1`](Export-FleetRequestHistory.ps1) | Request and task history with the failures picked out | Read | #12, #13 | `(REST via Invoke-RestMethod)` |
| [`Export-FleetDataCenterRegistration.ps1`](Export-FleetDataCenterRegistration.ps1) | Datacenter and vCenter registration record | Read | #16 | `(REST via Invoke-RestMethod)` |
| [`Import-FleetDataCenterRegistration.ps1`](Import-FleetDataCenterRegistration.ps1) | Recreate datacenter and vCenter registrations | Write | #16 | `(REST via Invoke-RestMethod)` |

## Export / import round trips

These pairs share an export envelope. The export writes it, the write-side script
validates it before changing anything, so the two always agree on the shape.

| Envelope schema | Export | Applies it |
|---|---|---|
| `fleet.certificate-locker` | [`Export-FleetCertificateLocker.ps1`](Export-FleetCertificateLocker.ps1) | [`Import-FleetCertificateLocker.ps1`](Import-FleetCertificateLocker.ps1) |
| `fleet.datacenter-registration` | [`Export-FleetDataCenterRegistration.ps1`](Export-FleetDataCenterRegistration.ps1) | [`Import-FleetDataCenterRegistration.ps1`](Import-FleetDataCenterRegistration.ps1) |

## Safety

Scripts marked **Write** change the target. They all support `-DiffOnly` to print the
plan and stop, and `-WhatIf` / `-Confirm` through `SupportsShouldProcess`. Run any of
them with `-DiffOnly` first.

Back to [Aria Suite Lifecycle](../README.md) | [repository index](../../../README.md)
