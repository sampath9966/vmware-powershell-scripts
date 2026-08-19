# vSphere Supervisor and VKS

The Supervisor sits between two teams and neither can see all of it. The vSphere side sees namespaces as folders with odd names; the Kubernetes side sees namespaces with no idea which datastore or VM class is behind them. These scripts join the two views, and make namespace configuration something you can capture and replay.

| | Product name |
|---|---|
| VCF 5.x | vSphere with Tanzu (Supervisor and TKG) |
| VCF 9.x | vSphere Supervisor and VKS |

> The product was renamed between generations. The scripts are split by the VCF
> release they target, not by the product name, so start from the version folder
> that matches your environment.

## Version folders

- [`5.x/`](5.x/) - 7 scripts for VCF 5.x
- [`9.x/`](9.x/) - 7 scripts for VCF 9.x

## Use cases

| Use case | Pain area | Mode | 5.x | 9.x |
|---|---|---|---|---|
| Namespaces with their limits, storage and access | #10 Cross-domain inventory | Read | [`Export-SupervisorNamespaceInventory.ps1`](5.x/Export-SupervisorNamespaceInventory.ps1) | [`Export-SupervisorNamespaceInventory.ps1`](9.x/Export-SupervisorNamespaceInventory.ps1) |
| Create namespaces and align limits from a captured config | #16 Config portability between environments | Write | [`Import-SupervisorNamespaceConfig.ps1`](5.x/Import-SupervisorNamespaceConfig.ps1) | [`Import-SupervisorNamespaceConfig.ps1`](9.x/Import-SupervisorNamespaceConfig.ps1) |
| Which VM belongs to which namespace and guest cluster | #10 Cross-domain inventory | Read | [`Export-SupervisorWorkloadMapping.ps1`](5.x/Export-SupervisorWorkloadMapping.ps1) | [`Export-SupervisorWorkloadMapping.ps1`](9.x/Export-SupervisorWorkloadMapping.ps1) |
| Supervisor and guest cluster versions and health | #3 BOM / version drift per domain, #1 Certificate expiry across the stack | Read | [`Export-SupervisorClusterHealth.ps1`](5.x/Export-SupervisorClusterHealth.ps1) | [`Export-SupervisorClusterHealth.ps1`](9.x/Export-SupervisorClusterHealth.ps1) |
| VM classes and which namespaces can use them | #16 Config portability between environments | Read | [`Export-SupervisorVmClass.ps1`](5.x/Export-SupervisorVmClass.ps1) | [`Export-SupervisorVmClass.ps1`](9.x/Export-SupervisorVmClass.ps1) |
| Recreate VM classes and bind them to namespaces | #16 Config portability between environments | Write | [`Import-SupervisorVmClass.ps1`](5.x/Import-SupervisorVmClass.ps1) | [`Import-SupervisorVmClass.ps1`](9.x/Import-SupervisorVmClass.ps1) |
| Namespaces with no backup protection | #15 Protection gaps | Read | [`Export-SupervisorProtectionGap.ps1`](5.x/Export-SupervisorProtectionGap.ps1) | [`Export-SupervisorProtectionGap.ps1`](9.x/Export-SupervisorProtectionGap.ps1) |

## A note on cmdlet names

Uses the VMware.VimAutomation.WorkloadManagement cmdlets where they cover the job, and the vSphere Automation API through Get-CisService for the namespace management surface they do not reach. Both connections are opened by every script here and closed again on exit.

Back to the [repository index](../../README.md).
