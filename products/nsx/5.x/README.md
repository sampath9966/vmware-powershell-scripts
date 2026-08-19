# NSX-T Data Center - VCF 5.x

PowerCLI scripts for NSX-T Data Center as shipped in VMware Cloud Foundation 5.x.

Every script is standalone: copy any single `.ps1` out of this folder and it runs on
its own. Nothing here dot-sources a shared helper.

| Script | Use case | Mode | Pain area | Modules |
|---|---|---|---|---|
| [`Export-NsxDfwRule.ps1`](Export-NsxDfwRule.ps1) | Every distributed firewall rule, flattened | Read | #8 | `VMware.VimAutomation.Nsxt` |
| [`Import-NsxDfwRule.ps1`](Import-NsxDfwRule.ps1) | Replay firewall rules with a diff first | Write | #8, #16 | `VMware.VimAutomation.Nsxt` |
| [`Export-NsxGroupMembership.ps1`](Export-NsxGroupMembership.ps1) | Which VMs are really in which security group | Read | #8, #10 | `VMware.VimAutomation.Nsxt` |
| [`Export-NsxVmTag.ps1`](Export-NsxVmTag.ps1) | NSX tag assignments on every VM | Read | #8, #16 | `VMware.VimAutomation.Nsxt` |
| [`Import-NsxVmTag.ps1`](Import-NsxVmTag.ps1) | Apply the NSX tag model to another NSX | Write | #8, #16 | `VMware.VimAutomation.Nsxt` |
| [`Export-NsxTransportNodeHealth.ps1`](Export-NsxTransportNodeHealth.ps1) | Transport and edge node state in one table | Read | #9 | `VMware.VimAutomation.Nsxt` |
| [`Export-NsxSegmentTopology.ps1`](Export-NsxSegmentTopology.ps1) | Segments, tier-1 and tier-0 topology in one place | Read | #16, #10 | `VMware.VimAutomation.Nsxt` |
| [`Import-NsxSegment.ps1`](Import-NsxSegment.ps1) | Recreate missing segments from a topology export | Write | #16 | `VMware.VimAutomation.Nsxt` |
| [`Export-NsxCertificate.ps1`](Export-NsxCertificate.ps1) | NSX certificate inventory and expiry | Read | #1 | `VMware.VimAutomation.Nsxt` |

## Export / import round trips

These pairs share an export envelope. The export writes it, the write-side script
validates it before changing anything, so the two always agree on the shape.

| Envelope schema | Export | Applies it |
|---|---|---|
| `nsx.dfw-rule` | [`Export-NsxDfwRule.ps1`](Export-NsxDfwRule.ps1) | [`Import-NsxDfwRule.ps1`](Import-NsxDfwRule.ps1) |
| `nsx.segment-topology` | [`Export-NsxSegmentTopology.ps1`](Export-NsxSegmentTopology.ps1) | [`Import-NsxSegment.ps1`](Import-NsxSegment.ps1) |
| `nsx.vm-tag` | [`Export-NsxVmTag.ps1`](Export-NsxVmTag.ps1) | [`Import-NsxVmTag.ps1`](Import-NsxVmTag.ps1) |

## Safety

Scripts marked **Write** change the target. They all support `-DiffOnly` to print the
plan and stop, and `-WhatIf` / `-Confirm` through `SupportsShouldProcess`. Run any of
them with `-DiffOnly` first.

Back to [NSX-T Data Center](../README.md) | [repository index](../../../README.md)
