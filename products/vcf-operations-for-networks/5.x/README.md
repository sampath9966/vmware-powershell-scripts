# Aria Operations for Networks - VCF 5.x

PowerCLI scripts for Aria Operations for Networks as shipped in VMware Cloud Foundation 5.x.

Every script is standalone: copy any single `.ps1` out of this folder and it runs on
its own. Nothing here dot-sources a shared helper.

| Script | Use case | Mode | Pain area | Modules |
|---|---|---|---|---|
| [`Export-NetworksDataSource.ps1`](Export-NetworksDataSource.ps1) | Data source inventory and collection health | Read | #9 | `(REST via Invoke-RestMethod)` |
| [`Import-NetworksDataSource.ps1`](Import-NetworksDataSource.ps1) | Add data sources in bulk from a file | Write | #16 | `(REST via Invoke-RestMethod)` |
| [`Export-NetworksVmFlow.ps1`](Export-NetworksVmFlow.ps1) | VM-to-VM flows for firewall rule planning | Read | #8 | `(REST via Invoke-RestMethod)` |
| [`Export-NetworksApplication.ps1`](Export-NetworksApplication.ps1) | Application definitions and their tier membership | Read | #16, #10 | `(REST via Invoke-RestMethod)` |
| [`Import-NetworksApplication.ps1`](Import-NetworksApplication.ps1) | Recreate the application model elsewhere | Write | #16 | `(REST via Invoke-RestMethod)` |
| [`Export-NetworksAlertDefinition.ps1`](Export-NetworksAlertDefinition.ps1) | Alert and problem definitions currently configured | Read | #13 | `(REST via Invoke-RestMethod)` |
| [`Export-NetworksVmPath.ps1`](Export-NetworksVmPath.ps1) | The network path between two VMs, hop by hop | Read | #10 | `(REST via Invoke-RestMethod)` |

## Export / import round trips

These pairs share an export envelope. The export writes it, the write-side script
validates it before changing anything, so the two always agree on the shape.

| Envelope schema | Export | Applies it |
|---|---|---|
| `networks.application` | [`Export-NetworksApplication.ps1`](Export-NetworksApplication.ps1) | [`Import-NetworksApplication.ps1`](Import-NetworksApplication.ps1) |
| `networks.data-source` | [`Export-NetworksDataSource.ps1`](Export-NetworksDataSource.ps1) | [`Import-NetworksDataSource.ps1`](Import-NetworksDataSource.ps1) |

## Safety

Scripts marked **Write** change the target. They all support `-DiffOnly` to print the
plan and stop, and `-WhatIf` / `-Confirm` through `SupportsShouldProcess`. Run any of
them with `-DiffOnly` first.

Back to [Aria Operations for Networks](../README.md) | [repository index](../../../README.md)
