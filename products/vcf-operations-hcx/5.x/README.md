# HCX - VCF 5.x

PowerCLI scripts for HCX as shipped in VMware Cloud Foundation 5.x.

Every script is standalone: copy any single `.ps1` out of this folder and it runs on
its own. Nothing here dot-sources a shared helper.

| Script | Use case | Mode | Pain area | Modules |
|---|---|---|---|---|
| [`Export-HcxSitePairing.ps1`](Export-HcxSitePairing.ps1) | Site pairings and service mesh layout | Read | #10 | `VMware.VimAutomation.Hcx` |
| [`Export-HcxMigrationStatus.ps1`](Export-HcxMigrationStatus.ps1) | Every migration and where it has got to | Read | #10 | `VMware.VimAutomation.Hcx` |
| [`Import-HcxMigrationWave.ps1`](Import-HcxMigrationWave.ps1) | Build a whole migration wave from a spreadsheet | Write | #10, #16 | `VMware.VimAutomation.Hcx` |
| [`Export-HcxNetworkExtension.ps1`](Export-HcxNetworkExtension.ps1) | Extended networks and their health | Read | #10, #9 | `VMware.VimAutomation.Hcx` |
| [`Export-HcxComputeProfile.ps1`](Export-HcxComputeProfile.ps1) | Compute and network profile definitions | Read | #16 | `VMware.VimAutomation.Hcx` |
| [`Export-HcxApplianceHealth.ps1`](Export-HcxApplianceHealth.ps1) | Interconnect appliance state and tunnel health | Read | #9 | `VMware.VimAutomation.Hcx` |
| [`Export-HcxMigrationValidation.ps1`](Export-HcxMigrationValidation.ps1) | Re-run validation on pending migrations | Read | #10 | `VMware.VimAutomation.Hcx` |

## Safety

Scripts marked **Write** change the target. They all support `-DiffOnly` to print the
plan and stop, and `-WhatIf` / `-Confirm` through `SupportsShouldProcess`. Run any of
them with `-DiffOnly` first.

Back to [HCX](../README.md) | [repository index](../../../README.md)
