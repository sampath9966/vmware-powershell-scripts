# vCenter - VCF 9.x

PowerCLI scripts for vCenter as shipped in VMware Cloud Foundation 9.x.

Every script is standalone: copy any single `.ps1` out of this folder and it runs on
its own. Nothing here dot-sources a shared helper.

| Script | Use case | Mode | Pain area | Modules |
|---|---|---|---|---|
| [`Export-VcVmInventory.ps1`](Export-VcVmInventory.ps1) | One flat VM inventory with folder path, tags and custom attributes | Read | #10 | `VMware.VimAutomation.Core`, `VMware.VimAutomation.Core` |
| [`Export-VcSnapshotInventory.ps1`](Export-VcSnapshotInventory.ps1) | Snapshot age, size and consolidation state across the estate | Read | #4 | `VMware.VimAutomation.Core` |
| [`Invoke-VcSnapshotCleanup.ps1`](Invoke-VcSnapshotCleanup.ps1) | Remove aged snapshots from a reviewed list | Write | #4 | `VMware.VimAutomation.Core` |
| [`Export-VcTagAssignment.ps1`](Export-VcTagAssignment.ps1) | Capture every tag, category and assignment | Read | #16, #10 | `VMware.VimAutomation.Core` |
| [`Import-VcTagAssignment.ps1`](Import-VcTagAssignment.ps1) | Replay the tagging model into another vCenter | Write | #16 | `VMware.VimAutomation.Core` |
| [`Export-VcLicenseInventory.ps1`](Export-VcLicenseInventory.ps1) | Licence keys, assignment and per-cluster core counts | Read | #7 | `VMware.VimAutomation.Core` |
| [`Export-VcOrphanedAsset.ps1`](Export-VcOrphanedAsset.ps1) | Orphaned VMs, zombie VMDKs and stale templates | Read | #5 | `VMware.VimAutomation.Core` |
| [`Invoke-VcOrphanedAssetCleanup.ps1`](Invoke-VcOrphanedAssetCleanup.ps1) | Remove reviewed orphaned VMs and zombie disks | Write | #5 | `VMware.VimAutomation.Core` |
| [`Export-VcEventAudit.ps1`](Export-VcEventAudit.ps1) | Who did what, extracted from the event log | Read | #13 | `VMware.VimAutomation.Core` |
| [`Export-VcPermission.ps1`](Export-VcPermission.ps1) | Roles, privileges and every permission assignment | Read | #16, #13 | `VMware.VimAutomation.Core` |
| [`Import-VcPermission.ps1`](Import-VcPermission.ps1) | Rebuild roles and permissions in another vCenter | Write | #16 | `VMware.VimAutomation.Core` |
| [`Export-VcDistributedSwitch.ps1`](Export-VcDistributedSwitch.ps1) | vDS, port group and VLAN map | Read | #16, #9 | `VMware.VimAutomation.Core`, `VMware.VimAutomation.Vds` |
| [`Import-VcDistributedSwitch.ps1`](Import-VcDistributedSwitch.ps1) | Recreate missing port groups from a switch export | Write | #16 | `VMware.VimAutomation.Core`, `VMware.VimAutomation.Vds` |

## Export / import round trips

These pairs share an export envelope. The export writes it, the write-side script
validates it before changing anything, so the two always agree on the shape.

| Envelope schema | Export | Applies it |
|---|---|---|
| `vcenter.distributed-switch` | [`Export-VcDistributedSwitch.ps1`](Export-VcDistributedSwitch.ps1) | [`Import-VcDistributedSwitch.ps1`](Import-VcDistributedSwitch.ps1) |
| `vcenter.orphaned-asset` | [`Export-VcOrphanedAsset.ps1`](Export-VcOrphanedAsset.ps1) | [`Invoke-VcOrphanedAssetCleanup.ps1`](Invoke-VcOrphanedAssetCleanup.ps1) |
| `vcenter.permission` | [`Export-VcPermission.ps1`](Export-VcPermission.ps1) | [`Import-VcPermission.ps1`](Import-VcPermission.ps1) |
| `vcenter.snapshot-inventory` | [`Export-VcSnapshotInventory.ps1`](Export-VcSnapshotInventory.ps1) | [`Invoke-VcSnapshotCleanup.ps1`](Invoke-VcSnapshotCleanup.ps1) |
| `vcenter.tag-assignment` | [`Export-VcTagAssignment.ps1`](Export-VcTagAssignment.ps1) | [`Import-VcTagAssignment.ps1`](Import-VcTagAssignment.ps1) |

## Safety

Scripts marked **Write** change the target. They all support `-DiffOnly` to print the
plan and stop, and `-WhatIf` / `-Confirm` through `SupportsShouldProcess`. Run any of
them with `-DiffOnly` first.

Back to [vCenter](../README.md) | [repository index](../../../README.md)
