# vSAN (ESA and OSA)

vSAN answers most questions through the health and capacity views, which are excellent to look at and impossible to export. When the question is 'across all twelve clusters, which health checks are failing, how much slack is left, and which objects are out of policy', the UI makes you ask it twelve times. These scripts ask once.

| | Product name |
|---|---|
| VCF 5.x | vSAN |
| VCF 9.x | vSAN (ESA and OSA) |

> The product was renamed between generations. The scripts are split by the VCF
> release they target, not by the product name, so start from the version folder
> that matches your environment.

## Version folders

- [`5.x/`](5.x/) - 7 scripts for VCF 5.x
- [`9.x/`](9.x/) - 7 scripts for VCF 9.x

## Use cases

| Use case | Pain area | Mode | 5.x | 9.x |
|---|---|---|---|---|
| Every failing health check across every vSAN cluster | #11 vSAN health, capacity, policy compliance | Read | [`Export-VsanHealthReport.ps1`](5.x/Export-VsanHealthReport.ps1) | [`Export-VsanHealthReport.ps1`](9.x/Export-VsanHealthReport.ps1) |
| Capacity, slack space and a simple runway estimate | #11 vSAN health, capacity, policy compliance | Read | [`Export-VsanCapacityForecast.ps1`](5.x/Export-VsanCapacityForecast.ps1) | [`Export-VsanCapacityForecast.ps1`](9.x/Export-VsanCapacityForecast.ps1) |
| Objects out of policy and components still resyncing | #11 vSAN health, capacity, policy compliance | Read | [`Export-VsanObjectCompliance.ps1`](5.x/Export-VsanObjectCompliance.ps1) | [`Export-VsanObjectCompliance.ps1`](9.x/Export-VsanObjectCompliance.ps1) |
| Storage policy definitions and where they are used | #16 Config portability between environments, #11 vSAN health, capacity, policy compliance | Read | [`Export-VsanStoragePolicy.ps1`](5.x/Export-VsanStoragePolicy.ps1) | [`Export-VsanStoragePolicy.ps1`](9.x/Export-VsanStoragePolicy.ps1) |
| Recreate missing storage policies in another vCenter | #16 Config portability between environments | Write | [`Import-VsanStoragePolicy.ps1`](5.x/Import-VsanStoragePolicy.ps1) | [`Import-VsanStoragePolicy.ps1`](9.x/Import-VsanStoragePolicy.ps1) |
| vSAN cluster settings, disk groups and witness layout | #16 Config portability between environments, #11 vSAN health, capacity, policy compliance | Read | [`Export-VsanClusterConfig.ps1`](5.x/Export-VsanClusterConfig.ps1) | [`Export-VsanClusterConfig.ps1`](9.x/Export-VsanClusterConfig.ps1) |
| Re-apply the policy to objects that drifted out of compliance | #11 vSAN health, capacity, policy compliance | Write | [`Invoke-VsanPolicyReapply.ps1`](5.x/Invoke-VsanPolicyReapply.ps1) | [`Invoke-VsanPolicyReapply.ps1`](9.x/Invoke-VsanPolicyReapply.ps1) |

## A note on cmdlet names

Health and capacity come from the VMware.VimAutomation.Storage cmdlets. Storage policies use the SPBM cmdlets, which already ship Export-SpbmStoragePolicy and Import-SpbmStoragePolicy for single policies - the scripts here wrap those into a whole-estate round trip with a diff.

Back to the [repository index](../../README.md).
