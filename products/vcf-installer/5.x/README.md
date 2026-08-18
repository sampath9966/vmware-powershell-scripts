# Cloud Builder - VCF 5.x

PowerCLI scripts for Cloud Builder as shipped in VMware Cloud Foundation 5.x.

Every script is standalone: copy any single `.ps1` out of this folder and it runs on
its own. Nothing here dot-sources a shared helper.

| Script | Use case | Mode | Pain area | Modules |
|---|---|---|---|---|
| [`Export-InstallerBringUpStatus.ps1`](Export-InstallerBringUpStatus.ps1) | Bring-up status and where it stopped | Read | #12 | `VMware.Sdk.Vcf.CloudBuilder` |
| [`Export-InstallerBringUpTask.ps1`](Export-InstallerBringUpTask.ps1) | The task tree flattened, with failures isolated | Read | #12 | `VMware.Sdk.Vcf.CloudBuilder` |
| [`Export-InstallerSpecValidation.ps1`](Export-InstallerSpecValidation.ps1) | Validate a deployment spec and flatten every finding | Read | #12 | `VMware.Sdk.Vcf.CloudBuilder` |
| [`Export-InstallerSddcSpec.ps1`](Export-InstallerSddcSpec.ps1) | Recover the spec a deployment was actually built from | Read | #16 | `VMware.Sdk.Vcf.CloudBuilder` |
| [`Import-InstallerSddcDeployment.ps1`](Import-InstallerSddcDeployment.ps1) | Start a bring-up from a validated spec | Write | #12 | `VMware.Sdk.Vcf.CloudBuilder` |
| [`Export-InstallerApplianceVersion.ps1`](Export-InstallerApplianceVersion.ps1) | Appliance version against the release it can deploy | Read | #3 | `VMware.Sdk.Vcf.CloudBuilder` |
| [`Export-InstallerHostPrecheck.ps1`](Export-InstallerHostPrecheck.ps1) | Per-host readiness before a bring-up | Read | #12, #6 | `VMware.Sdk.Vcf.CloudBuilder` |

## Export / import round trips

These pairs share an export envelope. The export writes it, the write-side script
validates it before changing anything, so the two always agree on the shape.

| Envelope schema | Export | Applies it |
|---|---|---|
| `installer.sddc-spec` | [`Export-InstallerSddcSpec.ps1`](Export-InstallerSddcSpec.ps1) | [`Import-InstallerSddcDeployment.ps1`](Import-InstallerSddcDeployment.ps1) |

## Safety

Scripts marked **Write** change the target. They all support `-DiffOnly` to print the
plan and stop, and `-WhatIf` / `-Confirm` through `SupportsShouldProcess`. Run any of
them with `-DiffOnly` first.

Back to [Cloud Builder](../README.md) | [repository index](../../../README.md)
