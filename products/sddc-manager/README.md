# SDDC Manager

SDDC Manager is the inventory and lifecycle brain of a VCF instance. It already knows every certificate, every credential, every bundle and every component version - the problem is that the UI shows them a handful at a time, per domain, with no export. These scripts pull the whole picture out in one pass.

| | Product name |
|---|---|
| VCF 5.x | SDDC Manager |
| VCF 9.x | SDDC Manager |

## Version folders

- [`5.x/`](5.x/) - 13 scripts for VCF 5.x
- [`9.x/`](9.x/) - 13 scripts for VCF 9.x

## Use cases

| Use case | Pain area | Mode | 5.x | 9.x |
|---|---|---|---|---|
| Certificate inventory and expiry across every component | #1 Certificate expiry across the stack | Read | [`Export-SddcCertificateInventory.ps1`](5.x/Export-SddcCertificateInventory.ps1) | [`Export-SddcCertificateInventory.ps1`](9.x/Export-SddcCertificateInventory.ps1) |
| Renew expiring certificates from the inventory export | #1 Certificate expiry across the stack | Write | [`Invoke-SddcCertificateRenewal.ps1`](5.x/Invoke-SddcCertificateRenewal.ps1) | [`Invoke-SddcCertificateRenewal.ps1`](9.x/Invoke-SddcCertificateRenewal.ps1) |
| Credential inventory and password age across every managed account | #2 Credential rotation and expiry | Read | [`Export-SddcCredentialInventory.ps1`](5.x/Export-SddcCredentialInventory.ps1) | [`Export-SddcCredentialInventory.ps1`](9.x/Export-SddcCredentialInventory.ps1) |
| Rotate passwords in controlled waves from a rotation plan | #2 Credential rotation and expiry | Write | [`Invoke-SddcCredentialRotation.ps1`](5.x/Invoke-SddcCredentialRotation.ps1) | [`Invoke-SddcCredentialRotation.ps1`](9.x/Invoke-SddcCredentialRotation.ps1) |
| BOM and version drift for every component in every domain | #3 BOM / version drift per domain | Read | [`Export-SddcBomDrift.ps1`](5.x/Export-SddcBomDrift.ps1) | [`Export-SddcBomDrift.ps1`](9.x/Export-SddcBomDrift.ps1) |
| Bundle inventory, applicability and download state | #12 Upgrade prechecks and bundle state | Read | [`Export-SddcBundleInventory.ps1`](5.x/Export-SddcBundleInventory.ps1) | [`Export-SddcBundleInventory.ps1`](9.x/Export-SddcBundleInventory.ps1) |
| Stage the bundles that are not downloaded yet | #12 Upgrade prechecks and bundle state | Write | [`Invoke-SddcBundleDownload.ps1`](5.x/Invoke-SddcBundleDownload.ps1) | [`Invoke-SddcBundleDownload.ps1`](9.x/Invoke-SddcBundleDownload.ps1) |
| One flat inventory of every domain, cluster and host | #10 Cross-domain inventory | Read | [`Export-SddcFleetInventory.ps1`](5.x/Export-SddcFleetInventory.ps1) | [`Export-SddcFleetInventory.ps1`](9.x/Export-SddcFleetInventory.ps1) |
| Capture commissioned hosts as a reusable commission spec | #10 Cross-domain inventory, #16 Config portability between environments | Read | [`Export-SddcHostCommissionSpec.ps1`](5.x/Export-SddcHostCommissionSpec.ps1) | [`Export-SddcHostCommissionSpec.ps1`](9.x/Export-SddcHostCommissionSpec.ps1) |
| Commission hosts in bulk from a spec file | #10 Cross-domain inventory, #16 Config portability between environments | Write | [`Import-SddcHostCommission.ps1`](5.x/Import-SddcHostCommission.ps1) | [`Import-SddcHostCommission.ps1`](9.x/Import-SddcHostCommission.ps1) |
| Run the upgrade precheck and flatten every finding | #12 Upgrade prechecks and bundle state | Read | [`Export-SddcUpgradePrecheck.ps1`](5.x/Export-SddcUpgradePrecheck.ps1) | [`Export-SddcUpgradePrecheck.ps1`](9.x/Export-SddcUpgradePrecheck.ps1) |
| Capture the password policy applied to every component | #2 Credential rotation and expiry, #16 Config portability between environments | Read | [`Export-SddcPasswordPolicy.ps1`](5.x/Export-SddcPasswordPolicy.ps1) | [`Export-SddcPasswordPolicy.ps1`](9.x/Export-SddcPasswordPolicy.ps1) |
| Apply a password policy baseline back to the instance | #2 Credential rotation and expiry, #16 Config portability between environments | Write | [`Import-SddcPasswordPolicy.ps1`](5.x/Import-SddcPasswordPolicy.ps1) | [`Import-SddcPasswordPolicy.ps1`](9.x/Import-SddcPasswordPolicy.ps1) |

## A note on cmdlet names

The VMware.Sdk.Vcf.SddcManager module is generated from the SDDC Manager OpenAPI specification, so cmdlet names track API operation IDs and can differ slightly between PowerCLI builds. Each script names the REST path it calls; if a cmdlet name does not resolve on your build, find the current one with `Get-VcfSddcManagerOperation -Path '<path>' -Method Get`.

Back to the [repository index](../../README.md).
