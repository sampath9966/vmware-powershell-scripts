# ESXi - VCF 5.x

PowerCLI scripts for ESXi as shipped in VMware Cloud Foundation 5.x.

Every script is standalone: copy any single `.ps1` out of this folder and it runs on
its own. Nothing here dot-sources a shared helper.

| Script | Use case | Mode | Pain area | Modules |
|---|---|---|---|---|
| [`Export-EsxHostInventory.ps1`](Export-EsxHostInventory.ps1) | Build, image, driver and firmware inventory per host | Read | #6, #3 | `VMware.VimAutomation.Core` |
| [`Export-EsxConfigDrift.ps1`](Export-EsxConfigDrift.ps1) | NTP, DNS, syslog and lockdown drift across hosts | Read | #9 | `VMware.VimAutomation.Core` |
| [`Import-EsxConfigBaseline.ps1`](Import-EsxConfigBaseline.ps1) | Push a host configuration baseline back out | Write | #9 | `VMware.VimAutomation.Core` |
| [`Export-EsxAdvancedSetting.ps1`](Export-EsxAdvancedSetting.ps1) | Advanced settings baseline and per-host deviation | Read | #9 | `VMware.VimAutomation.Core` |
| [`Import-EsxAdvancedSetting.ps1`](Import-EsxAdvancedSetting.ps1) | Apply an advanced settings baseline to hosts that drifted | Write | #9 | `VMware.VimAutomation.Core` |
| [`Export-EsxServiceAndFirewall.ps1`](Export-EsxServiceAndFirewall.ps1) | Service state and firewall rule exceptions per host | Read | #9 | `VMware.VimAutomation.Core` |
| [`Export-EsxHardwareHealth.ps1`](Export-EsxHardwareHealth.ps1) | Hardware sensor and health alarm state per host | Read | #6 | `VMware.VimAutomation.Core` |
| [`Export-EsxCoredumpAndLogConfig.ps1`](Export-EsxCoredumpAndLogConfig.ps1) | Coredump, scratch and persistent log location per host | Read | #9 | `VMware.VimAutomation.Core` |
| [`Invoke-EsxLogConfigRemediation.ps1`](Invoke-EsxLogConfigRemediation.ps1) | Point logs and dumps at persistent storage | Write | #9 | `VMware.VimAutomation.Core` |
| [`Export-EsxCertificate.ps1`](Export-EsxCertificate.ps1) | Host certificate subject, issuer and expiry | Read | #1 | `VMware.VimAutomation.Core` |

## Export / import round trips

These pairs share an export envelope. The export writes it, the write-side script
validates it before changing anything, so the two always agree on the shape.

| Envelope schema | Export | Applies it |
|---|---|---|
| `esx.advanced-setting` | [`Export-EsxAdvancedSetting.ps1`](Export-EsxAdvancedSetting.ps1) | [`Import-EsxAdvancedSetting.ps1`](Import-EsxAdvancedSetting.ps1) |
| `esx.coredump-log` | [`Export-EsxCoredumpAndLogConfig.ps1`](Export-EsxCoredumpAndLogConfig.ps1) | [`Invoke-EsxLogConfigRemediation.ps1`](Invoke-EsxLogConfigRemediation.ps1) |
| `esx.host-config` | [`Export-EsxConfigDrift.ps1`](Export-EsxConfigDrift.ps1) | [`Import-EsxConfigBaseline.ps1`](Import-EsxConfigBaseline.ps1) |

## Safety

Scripts marked **Write** change the target. They all support `-DiffOnly` to print the
plan and stop, and `-WhatIf` / `-Confirm` through `SupportsShouldProcess`. Run any of
them with `-DiffOnly` first.

Back to [ESXi](../README.md) | [repository index](../../../README.md)
