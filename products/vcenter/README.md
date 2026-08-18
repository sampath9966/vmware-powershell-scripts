# vCenter

vCenter holds the answers to most day-to-day questions, but almost never in one view. Tags live in one place, custom attributes in another, folder paths are only visible in the tree, and snapshots are per-VM. These scripts flatten those into single tables, and give the config-shaped ones a matching import so a second vCenter can be brought to the same state.

| | Product name |
|---|---|
| VCF 5.x | vCenter Server |
| VCF 9.x | vCenter |

> The product was renamed between generations. The scripts are split by the VCF
> release they target, not by the product name, so start from the version folder
> that matches your environment.

## Version folders

- [`5.x/`](5.x/) - 13 scripts for VCF 5.x
- [`9.x/`](9.x/) - 13 scripts for VCF 9.x

## Use cases

| Use case | Pain area | Mode | 5.x | 9.x |
|---|---|---|---|---|
| One flat VM inventory with folder path, tags and custom attributes | #10 Cross-domain inventory | Read | [`Export-VcVmInventory.ps1`](5.x/Export-VcVmInventory.ps1) | [`Export-VcVmInventory.ps1`](9.x/Export-VcVmInventory.ps1) |
| Snapshot age, size and consolidation state across the estate | #4 Snapshot sprawl | Read | [`Export-VcSnapshotInventory.ps1`](5.x/Export-VcSnapshotInventory.ps1) | [`Export-VcSnapshotInventory.ps1`](9.x/Export-VcSnapshotInventory.ps1) |
| Remove aged snapshots from a reviewed list | #4 Snapshot sprawl | Write | [`Invoke-VcSnapshotCleanup.ps1`](5.x/Invoke-VcSnapshotCleanup.ps1) | [`Invoke-VcSnapshotCleanup.ps1`](9.x/Invoke-VcSnapshotCleanup.ps1) |
| Capture every tag, category and assignment | #16 Config portability between environments, #10 Cross-domain inventory | Read | [`Export-VcTagAssignment.ps1`](5.x/Export-VcTagAssignment.ps1) | [`Export-VcTagAssignment.ps1`](9.x/Export-VcTagAssignment.ps1) |
| Replay the tagging model into another vCenter | #16 Config portability between environments | Write | [`Import-VcTagAssignment.ps1`](5.x/Import-VcTagAssignment.ps1) | [`Import-VcTagAssignment.ps1`](9.x/Import-VcTagAssignment.ps1) |
| Licence keys, assignment and per-cluster core counts | #7 Licensing and core counts | Read | [`Export-VcLicenseInventory.ps1`](5.x/Export-VcLicenseInventory.ps1) | [`Export-VcLicenseInventory.ps1`](9.x/Export-VcLicenseInventory.ps1) |
| Orphaned VMs, zombie VMDKs and stale templates | #5 Orphaned and zombie assets | Read | [`Export-VcOrphanedAsset.ps1`](5.x/Export-VcOrphanedAsset.ps1) | [`Export-VcOrphanedAsset.ps1`](9.x/Export-VcOrphanedAsset.ps1) |
| Remove reviewed orphaned VMs and zombie disks | #5 Orphaned and zombie assets | Write | [`Invoke-VcOrphanedAssetCleanup.ps1`](5.x/Invoke-VcOrphanedAssetCleanup.ps1) | [`Invoke-VcOrphanedAssetCleanup.ps1`](9.x/Invoke-VcOrphanedAssetCleanup.ps1) |
| Who did what, extracted from the event log | #13 Alarm noise and audit-trail extraction | Read | [`Export-VcEventAudit.ps1`](5.x/Export-VcEventAudit.ps1) | [`Export-VcEventAudit.ps1`](9.x/Export-VcEventAudit.ps1) |
| Roles, privileges and every permission assignment | #16 Config portability between environments, #13 Alarm noise and audit-trail extraction | Read | [`Export-VcPermission.ps1`](5.x/Export-VcPermission.ps1) | [`Export-VcPermission.ps1`](9.x/Export-VcPermission.ps1) |
| Rebuild roles and permissions in another vCenter | #16 Config portability between environments | Write | [`Import-VcPermission.ps1`](5.x/Import-VcPermission.ps1) | [`Import-VcPermission.ps1`](9.x/Import-VcPermission.ps1) |
| vDS, port group and VLAN map | #16 Config portability between environments, #9 Config drift (NTP/DNS/syslog/lockdown) | Read | [`Export-VcDistributedSwitch.ps1`](5.x/Export-VcDistributedSwitch.ps1) | [`Export-VcDistributedSwitch.ps1`](9.x/Export-VcDistributedSwitch.ps1) |
| Recreate missing port groups from a switch export | #16 Config portability between environments | Write | [`Import-VcDistributedSwitch.ps1`](5.x/Import-VcDistributedSwitch.ps1) | [`Import-VcDistributedSwitch.ps1`](9.x/Import-VcDistributedSwitch.ps1) |

## A note on cmdlet names

These scripts use the shipped VMware.VimAutomation cmdlets and fall back to Get-View only where no cmdlet exposes the property. The cmdlet surface is broadly the same across both generations; where a script genuinely differs between VCF 5.x and 9.x, the two version folders carry different logic and the help says so.

Back to the [repository index](../../README.md).
