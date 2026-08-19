# vSphere with Tanzu (Supervisor and TKG) - VCF 5.x

PowerCLI scripts for vSphere with Tanzu (Supervisor and TKG) as shipped in VMware Cloud Foundation 5.x.

Every script is standalone: copy any single `.ps1` out of this folder and it runs on
its own. Nothing here dot-sources a shared helper.

| Script | Use case | Mode | Pain area | Modules |
|---|---|---|---|---|
| [`Export-SupervisorNamespaceInventory.ps1`](Export-SupervisorNamespaceInventory.ps1) | Namespaces with their limits, storage and access | Read | #10 | `VMware.VimAutomation.Core`, `VMware.VimAutomation.WorkloadManagement`, `VMware.VimAutomation.Cis.Core` |
| [`Import-SupervisorNamespaceConfig.ps1`](Import-SupervisorNamespaceConfig.ps1) | Create namespaces and align limits from a captured config | Write | #16 | `VMware.VimAutomation.Core`, `VMware.VimAutomation.WorkloadManagement`, `VMware.VimAutomation.Cis.Core` |
| [`Export-SupervisorWorkloadMapping.ps1`](Export-SupervisorWorkloadMapping.ps1) | Which VM belongs to which namespace and guest cluster | Read | #10 | `VMware.VimAutomation.Core`, `VMware.VimAutomation.WorkloadManagement`, `VMware.VimAutomation.Cis.Core` |
| [`Export-SupervisorClusterHealth.ps1`](Export-SupervisorClusterHealth.ps1) | Supervisor and guest cluster versions and health | Read | #3, #1 | `VMware.VimAutomation.Core`, `VMware.VimAutomation.WorkloadManagement`, `VMware.VimAutomation.Cis.Core` |
| [`Export-SupervisorVmClass.ps1`](Export-SupervisorVmClass.ps1) | VM classes and which namespaces can use them | Read | #16 | `VMware.VimAutomation.Core`, `VMware.VimAutomation.WorkloadManagement`, `VMware.VimAutomation.Cis.Core` |
| [`Import-SupervisorVmClass.ps1`](Import-SupervisorVmClass.ps1) | Recreate VM classes and bind them to namespaces | Write | #16 | `VMware.VimAutomation.Core`, `VMware.VimAutomation.WorkloadManagement`, `VMware.VimAutomation.Cis.Core` |
| [`Export-SupervisorProtectionGap.ps1`](Export-SupervisorProtectionGap.ps1) | Namespaces with no backup protection | Read | #15 | `VMware.VimAutomation.Core`, `VMware.VimAutomation.WorkloadManagement`, `VMware.VimAutomation.Cis.Core` |

## Export / import round trips

These pairs share an export envelope. The export writes it, the write-side script
validates it before changing anything, so the two always agree on the shape.

| Envelope schema | Export | Applies it |
|---|---|---|
| `supervisor.namespace-inventory` | [`Export-SupervisorNamespaceInventory.ps1`](Export-SupervisorNamespaceInventory.ps1) | [`Import-SupervisorNamespaceConfig.ps1`](Import-SupervisorNamespaceConfig.ps1) |
| `supervisor.vm-class` | [`Export-SupervisorVmClass.ps1`](Export-SupervisorVmClass.ps1) | [`Import-SupervisorVmClass.ps1`](Import-SupervisorVmClass.ps1) |

## Safety

Scripts marked **Write** change the target. They all support `-DiffOnly` to print the
plan and stop, and `-WhatIf` / `-Confirm` through `SupportsShouldProcess`. Run any of
them with `-DiffOnly` first.

Back to [vSphere with Tanzu (Supervisor and TKG)](../README.md) | [repository index](../../../README.md)
