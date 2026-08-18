# SDDC Manager - VCF 5.x

PowerCLI scripts for SDDC Manager as shipped in VMware Cloud Foundation 5.x.

Every script is standalone: copy any single `.ps1` out of this folder and it runs on
its own. Nothing here dot-sources a shared helper.

| Script | Use case | Mode | Pain area | Modules |
|---|---|---|---|---|
| [`Export-SddcCertificateInventory.ps1`](Export-SddcCertificateInventory.ps1) | Certificate inventory and expiry across every component | Read | #1 | `VMware.Sdk.Vcf.SddcManager` |
| [`Invoke-SddcCertificateRenewal.ps1`](Invoke-SddcCertificateRenewal.ps1) | Renew expiring certificates from the inventory export | Write | #1 | `VMware.Sdk.Vcf.SddcManager` |
| [`Export-SddcCredentialInventory.ps1`](Export-SddcCredentialInventory.ps1) | Credential inventory and password age across every managed account | Read | #2 | `VMware.Sdk.Vcf.SddcManager` |
| [`Invoke-SddcCredentialRotation.ps1`](Invoke-SddcCredentialRotation.ps1) | Rotate passwords in controlled waves from a rotation plan | Write | #2 | `VMware.Sdk.Vcf.SddcManager` |
| [`Export-SddcBomDrift.ps1`](Export-SddcBomDrift.ps1) | BOM and version drift for every component in every domain | Read | #3 | `VMware.Sdk.Vcf.SddcManager` |
| [`Export-SddcBundleInventory.ps1`](Export-SddcBundleInventory.ps1) | Bundle inventory, applicability and download state | Read | #12 | `VMware.Sdk.Vcf.SddcManager` |
| [`Invoke-SddcBundleDownload.ps1`](Invoke-SddcBundleDownload.ps1) | Stage the bundles that are not downloaded yet | Write | #12 | `VMware.Sdk.Vcf.SddcManager` |
| [`Export-SddcFleetInventory.ps1`](Export-SddcFleetInventory.ps1) | One flat inventory of every domain, cluster and host | Read | #10 | `VMware.Sdk.Vcf.SddcManager` |
| [`Export-SddcHostCommissionSpec.ps1`](Export-SddcHostCommissionSpec.ps1) | Capture commissioned hosts as a reusable commission spec | Read | #10, #16 | `VMware.Sdk.Vcf.SddcManager` |
| [`Import-SddcHostCommission.ps1`](Import-SddcHostCommission.ps1) | Commission hosts in bulk from a spec file | Write | #10, #16 | `VMware.Sdk.Vcf.SddcManager` |
| [`Export-SddcUpgradePrecheck.ps1`](Export-SddcUpgradePrecheck.ps1) | Run the upgrade precheck and flatten every finding | Read | #12 | `VMware.Sdk.Vcf.SddcManager` |
| [`Export-SddcPasswordPolicy.ps1`](Export-SddcPasswordPolicy.ps1) | Capture the password policy applied to every component | Read | #2, #16 | `VMware.Sdk.Vcf.SddcManager` |
| [`Import-SddcPasswordPolicy.ps1`](Import-SddcPasswordPolicy.ps1) | Apply a password policy baseline back to the instance | Write | #2, #16 | `VMware.Sdk.Vcf.SddcManager` |

## Export / import round trips

These pairs share an export envelope. The export writes it, the write-side script
validates it before changing anything, so the two always agree on the shape.

| Envelope schema | Export | Applies it |
|---|---|---|
| `vcf.sddc.bundle-inventory` | [`Export-SddcBundleInventory.ps1`](Export-SddcBundleInventory.ps1) | [`Invoke-SddcBundleDownload.ps1`](Invoke-SddcBundleDownload.ps1) |
| `vcf.sddc.certificate-inventory` | [`Export-SddcCertificateInventory.ps1`](Export-SddcCertificateInventory.ps1) | [`Invoke-SddcCertificateRenewal.ps1`](Invoke-SddcCertificateRenewal.ps1) |
| `vcf.sddc.credential-inventory` | [`Export-SddcCredentialInventory.ps1`](Export-SddcCredentialInventory.ps1) | [`Invoke-SddcCredentialRotation.ps1`](Invoke-SddcCredentialRotation.ps1) |
| `vcf.sddc.host-commission-spec` | [`Export-SddcHostCommissionSpec.ps1`](Export-SddcHostCommissionSpec.ps1) | [`Import-SddcHostCommission.ps1`](Import-SddcHostCommission.ps1) |
| `vcf.sddc.password-policy` | [`Export-SddcPasswordPolicy.ps1`](Export-SddcPasswordPolicy.ps1) | [`Import-SddcPasswordPolicy.ps1`](Import-SddcPasswordPolicy.ps1) |

## Safety

Scripts marked **Write** change the target. They all support `-DiffOnly` to print the
plan and stop, and `-WhatIf` / `-Confirm` through `SupportsShouldProcess`. Run any of
them with `-DiffOnly` first.

Back to [SDDC Manager](../README.md) | [repository index](../../../README.md)
