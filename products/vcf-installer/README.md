# VCF Installer

The appliance that performs the initial deployment is the one nobody automates, because it is used once. That is exactly why it goes wrong: the spec is hand-edited, validation is read off a screen, and the failure detail is buried in a nested task tree. These scripts flatten the validation and task output, and let the spec be validated and replayed as a file.

| | Product name |
|---|---|
| VCF 5.x | Cloud Builder |
| VCF 9.x | VCF Installer |

> The product was renamed between generations. The scripts are split by the VCF
> release they target, not by the product name, so start from the version folder
> that matches your environment.

## Version folders

- [`5.x/`](5.x/) - 7 scripts for VCF 5.x
- [`9.x/`](9.x/) - 7 scripts for VCF 9.x

## Use cases

| Use case | Pain area | Mode | 5.x | 9.x |
|---|---|---|---|---|
| Bring-up status and where it stopped | #12 Upgrade prechecks and bundle state | Read | [`Export-InstallerBringUpStatus.ps1`](5.x/Export-InstallerBringUpStatus.ps1) | [`Export-InstallerBringUpStatus.ps1`](9.x/Export-InstallerBringUpStatus.ps1) |
| The task tree flattened, with failures isolated | #12 Upgrade prechecks and bundle state | Read | [`Export-InstallerBringUpTask.ps1`](5.x/Export-InstallerBringUpTask.ps1) | [`Export-InstallerBringUpTask.ps1`](9.x/Export-InstallerBringUpTask.ps1) |
| Validate a deployment spec and flatten every finding | #12 Upgrade prechecks and bundle state | Read | [`Export-InstallerSpecValidation.ps1`](5.x/Export-InstallerSpecValidation.ps1) | [`Export-InstallerSpecValidation.ps1`](9.x/Export-InstallerSpecValidation.ps1) |
| Recover the spec a deployment was actually built from | #16 Config portability between environments | Read | [`Export-InstallerSddcSpec.ps1`](5.x/Export-InstallerSddcSpec.ps1) | [`Export-InstallerSddcSpec.ps1`](9.x/Export-InstallerSddcSpec.ps1) |
| Start a bring-up from a validated spec | #12 Upgrade prechecks and bundle state | Write | [`Import-InstallerSddcDeployment.ps1`](5.x/Import-InstallerSddcDeployment.ps1) | [`Import-InstallerSddcDeployment.ps1`](9.x/Import-InstallerSddcDeployment.ps1) |
| Appliance version against the release it can deploy | #3 BOM / version drift per domain | Read | [`Export-InstallerApplianceVersion.ps1`](5.x/Export-InstallerApplianceVersion.ps1) | [`Export-InstallerApplianceVersion.ps1`](9.x/Export-InstallerApplianceVersion.ps1) |
| Per-host readiness before a bring-up | #12 Upgrade prechecks and bundle state, #6 Firmware/driver vs HCL compliance | Read | [`Export-InstallerHostPrecheck.ps1`](5.x/Export-InstallerHostPrecheck.ps1) | [`Export-InstallerHostPrecheck.ps1`](9.x/Export-InstallerHostPrecheck.ps1) |

## A note on cmdlet names

This is the one product where the two version folders genuinely differ. VCF 5.x is served by Cloud Builder through VMware.Sdk.Vcf.CloudBuilder; VCF 9.x is served by the VCF Installer appliance through VMware.Sdk.Vcf.Installer. The cmdlet names track the operation ids of each appliance's API, so if one does not resolve on your build, list the current set with Get-VcfCloudBuilderOperation or Get-VcfInstallerOperation.

Back to the [repository index](../../README.md).
