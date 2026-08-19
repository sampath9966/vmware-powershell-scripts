# NSX (including vDefend)

Getting a straight answer out of NSX is the most-blogged pain point in the whole stack. 'Show me the firewall rules' means paging through a policy tree. 'Which VMs are in this group' means opening the group and reading effective members one page at a time. 'What changed' means comparing screenshots. These scripts turn each of those into a table, and give the rule and tag models a replayable import.

| | Product name |
|---|---|
| VCF 5.x | NSX-T Data Center |
| VCF 9.x | NSX (including vDefend) |

> The product was renamed between generations. The scripts are split by the VCF
> release they target, not by the product name, so start from the version folder
> that matches your environment.

## Version folders

- [`5.x/`](5.x/) - 9 scripts for VCF 5.x
- [`9.x/`](9.x/) - 9 scripts for VCF 9.x

## Use cases

| Use case | Pain area | Mode | 5.x | 9.x |
|---|---|---|---|---|
| Every distributed firewall rule, flattened | #8 DFW rules and effective membership | Read | [`Export-NsxDfwRule.ps1`](5.x/Export-NsxDfwRule.ps1) | [`Export-NsxDfwRule.ps1`](9.x/Export-NsxDfwRule.ps1) |
| Replay firewall rules with a diff first | #8 DFW rules and effective membership, #16 Config portability between environments | Write | [`Import-NsxDfwRule.ps1`](5.x/Import-NsxDfwRule.ps1) | [`Import-NsxDfwRule.ps1`](9.x/Import-NsxDfwRule.ps1) |
| Which VMs are really in which security group | #8 DFW rules and effective membership, #10 Cross-domain inventory | Read | [`Export-NsxGroupMembership.ps1`](5.x/Export-NsxGroupMembership.ps1) | [`Export-NsxGroupMembership.ps1`](9.x/Export-NsxGroupMembership.ps1) |
| NSX tag assignments on every VM | #8 DFW rules and effective membership, #16 Config portability between environments | Read | [`Export-NsxVmTag.ps1`](5.x/Export-NsxVmTag.ps1) | [`Export-NsxVmTag.ps1`](9.x/Export-NsxVmTag.ps1) |
| Apply the NSX tag model to another NSX | #8 DFW rules and effective membership, #16 Config portability between environments | Write | [`Import-NsxVmTag.ps1`](5.x/Import-NsxVmTag.ps1) | [`Import-NsxVmTag.ps1`](9.x/Import-NsxVmTag.ps1) |
| Transport and edge node state in one table | #9 Config drift (NTP/DNS/syslog/lockdown) | Read | [`Export-NsxTransportNodeHealth.ps1`](5.x/Export-NsxTransportNodeHealth.ps1) | [`Export-NsxTransportNodeHealth.ps1`](9.x/Export-NsxTransportNodeHealth.ps1) |
| Segments, tier-1 and tier-0 topology in one place | #16 Config portability between environments, #10 Cross-domain inventory | Read | [`Export-NsxSegmentTopology.ps1`](5.x/Export-NsxSegmentTopology.ps1) | [`Export-NsxSegmentTopology.ps1`](9.x/Export-NsxSegmentTopology.ps1) |
| Recreate missing segments from a topology export | #16 Config portability between environments | Write | [`Import-NsxSegment.ps1`](5.x/Import-NsxSegment.ps1) | [`Import-NsxSegment.ps1`](9.x/Import-NsxSegment.ps1) |
| NSX certificate inventory and expiry | #1 Certificate expiry across the stack | Read | [`Export-NsxCertificate.ps1`](5.x/Export-NsxCertificate.ps1) | [`Export-NsxCertificate.ps1`](9.x/Export-NsxCertificate.ps1) |

## A note on cmdlet names

NSX has no first-class PowerCLI cmdlets beyond connect and disconnect. Everything here goes through the service proxies: Get-NsxtPolicyService for the Policy API and Get-NsxtService for the Manager API. Each script names the service it binds to, so the path back to the API reference is short.

Back to the [repository index](../../README.md).
