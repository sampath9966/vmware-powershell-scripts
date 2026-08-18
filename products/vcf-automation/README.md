# VCF Automation

Automation is where sprawl is created and where it is hardest to see. Deployments have owners who left, leases that were extended forever, and resources nobody has logged into in a year - and the reclamation view shows a fraction of it. These scripts pull the deployment estate out with the numbers attached, and make the platform configuration portable.

| | Product name |
|---|---|
| VCF 5.x | Aria Automation |
| VCF 9.x | VCF Automation |

> The product was renamed between generations. The scripts are split by the VCF
> release they target, not by the product name, so start from the version folder
> that matches your environment.

## Version folders

- [`5.x/`](5.x/) - 8 scripts for VCF 5.x
- [`9.x/`](9.x/) - 8 scripts for VCF 9.x

## Use cases

| Use case | Pain area | Mode | 5.x | 9.x |
|---|---|---|---|---|
| Every deployment with owner, project, lease and cost | #10 Cross-domain inventory, #5 Orphaned and zombie assets | Read | [`Export-AutomationDeploymentInventory.ps1`](5.x/Export-AutomationDeploymentInventory.ps1) | [`Export-AutomationDeploymentInventory.ps1`](9.x/Export-AutomationDeploymentInventory.ps1) |
| Expire or destroy reviewed idle deployments | #5 Orphaned and zombie assets, #14 Rightsizing and idle workloads | Write | [`Invoke-AutomationDeploymentExpiry.ps1`](5.x/Invoke-AutomationDeploymentExpiry.ps1) | [`Invoke-AutomationDeploymentExpiry.ps1`](9.x/Invoke-AutomationDeploymentExpiry.ps1) |
| Cloud templates with their YAML and version history | #16 Config portability between environments | Read | [`Export-AutomationCloudTemplate.ps1`](5.x/Export-AutomationCloudTemplate.ps1) | [`Export-AutomationCloudTemplate.ps1`](9.x/Export-AutomationCloudTemplate.ps1) |
| Push cloud templates into another Automation instance | #16 Config portability between environments | Write | [`Import-AutomationCloudTemplate.ps1`](5.x/Import-AutomationCloudTemplate.ps1) | [`Import-AutomationCloudTemplate.ps1`](9.x/Import-AutomationCloudTemplate.ps1) |
| Projects, membership and their cloud zone bindings | #16 Config portability between environments, #10 Cross-domain inventory | Read | [`Export-AutomationProject.ps1`](5.x/Export-AutomationProject.ps1) | [`Export-AutomationProject.ps1`](9.x/Export-AutomationProject.ps1) |
| Recreate projects and their membership | #16 Config portability between environments | Write | [`Import-AutomationProject.ps1`](5.x/Import-AutomationProject.ps1) | [`Import-AutomationProject.ps1`](9.x/Import-AutomationProject.ps1) |
| Cloud zones, flavor and image mappings | #16 Config portability between environments | Read | [`Export-AutomationCloudZoneMapping.ps1`](5.x/Export-AutomationCloudZoneMapping.ps1) | [`Export-AutomationCloudZoneMapping.ps1`](9.x/Export-AutomationCloudZoneMapping.ps1) |
| Provisioning request failures with the actual error | #13 Alarm noise and audit-trail extraction | Read | [`Export-AutomationRequestFailure.ps1`](5.x/Export-AutomationRequestFailure.ps1) | [`Export-AutomationRequestFailure.ps1`](9.x/Export-AutomationRequestFailure.ps1) |

## A note on cmdlet names

Authenticates through /csp/gateway/am/api/login and exchanges the refresh token at /iaas/api/login for a bearer token, which is the documented two-step flow. All endpoints page at 200 items; the scripts follow the pagination rather than taking the first page.

Back to the [repository index](../../README.md).
