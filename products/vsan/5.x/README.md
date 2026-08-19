# vSAN - VCF 5.x

PowerCLI scripts for vSAN as shipped in VMware Cloud Foundation 5.x.

Every script is standalone: copy any single `.ps1` out of this folder and it runs on
its own. Nothing here dot-sources a shared helper.

| Script | Use case | Mode | Pain area | Modules |
|---|---|---|---|---|
| [`Export-VsanHealthReport.ps1`](Export-VsanHealthReport.ps1) | Every failing health check across every vSAN cluster | Read | #11 | `VMware.VimAutomation.Core`, `VMware.VimAutomation.Storage` |
| [`Export-VsanCapacityForecast.ps1`](Export-VsanCapacityForecast.ps1) | Capacity, slack space and a simple runway estimate | Read | #11 | `VMware.VimAutomation.Core`, `VMware.VimAutomation.Storage` |
| [`Export-VsanObjectCompliance.ps1`](Export-VsanObjectCompliance.ps1) | Objects out of policy and components still resyncing | Read | #11 | `VMware.VimAutomation.Core`, `VMware.VimAutomation.Storage` |
| [`Export-VsanStoragePolicy.ps1`](Export-VsanStoragePolicy.ps1) | Storage policy definitions and where they are used | Read | #16, #11 | `VMware.VimAutomation.Core`, `VMware.VimAutomation.Storage` |
| [`Import-VsanStoragePolicy.ps1`](Import-VsanStoragePolicy.ps1) | Recreate missing storage policies in another vCenter | Write | #16 | `VMware.VimAutomation.Core`, `VMware.VimAutomation.Storage` |
| [`Export-VsanClusterConfig.ps1`](Export-VsanClusterConfig.ps1) | vSAN cluster settings, disk groups and witness layout | Read | #16, #11 | `VMware.VimAutomation.Core`, `VMware.VimAutomation.Storage` |
| [`Invoke-VsanPolicyReapply.ps1`](Invoke-VsanPolicyReapply.ps1) | Re-apply the policy to objects that drifted out of compliance | Write | #11 | `VMware.VimAutomation.Core`, `VMware.VimAutomation.Storage` |

## Export / import round trips

These pairs share an export envelope. The export writes it, the write-side script
validates it before changing anything, so the two always agree on the shape.

| Envelope schema | Export | Applies it |
|---|---|---|
| `vsan.object-compliance` | [`Export-VsanObjectCompliance.ps1`](Export-VsanObjectCompliance.ps1) | [`Invoke-VsanPolicyReapply.ps1`](Invoke-VsanPolicyReapply.ps1) |
| `vsan.storage-policy` | [`Export-VsanStoragePolicy.ps1`](Export-VsanStoragePolicy.ps1) | [`Import-VsanStoragePolicy.ps1`](Import-VsanStoragePolicy.ps1) |

## Safety

Scripts marked **Write** change the target. They all support `-DiffOnly` to print the
plan and stop, and `-WhatIf` / `-Confirm` through `SupportsShouldProcess`. Run any of
them with `-DiffOnly` first.

Back to [vSAN](../README.md) | [repository index](../../../README.md)
