# ESX

Host-level facts are scattered across the hardware view, the advanced settings tree, the services tab and esxcli. The questions that matter - which driver and firmware is every HBA on, which hosts drifted off the NTP standard, where is coredump actually pointing - need all of those at once. These scripts collect them per host and hand back one table, with a matching import for the settings that should be identical everywhere.

| | Product name |
|---|---|
| VCF 5.x | ESXi |
| VCF 9.x | ESX |

> The product was renamed between generations. The scripts are split by the VCF
> release they target, not by the product name, so start from the version folder
> that matches your environment.

## Version folders

- [`5.x/`](5.x/) - 10 scripts for VCF 5.x
- [`9.x/`](9.x/) - 10 scripts for VCF 9.x

## Use cases

| Use case | Pain area | Mode | 5.x | 9.x |
|---|---|---|---|---|
| Build, image, driver and firmware inventory per host | #6 Firmware/driver vs HCL compliance, #3 BOM / version drift per domain | Read | [`Export-EsxHostInventory.ps1`](5.x/Export-EsxHostInventory.ps1) | [`Export-EsxHostInventory.ps1`](9.x/Export-EsxHostInventory.ps1) |
| NTP, DNS, syslog and lockdown drift across hosts | #9 Config drift (NTP/DNS/syslog/lockdown) | Read | [`Export-EsxConfigDrift.ps1`](5.x/Export-EsxConfigDrift.ps1) | [`Export-EsxConfigDrift.ps1`](9.x/Export-EsxConfigDrift.ps1) |
| Push a host configuration baseline back out | #9 Config drift (NTP/DNS/syslog/lockdown) | Write | [`Import-EsxConfigBaseline.ps1`](5.x/Import-EsxConfigBaseline.ps1) | [`Import-EsxConfigBaseline.ps1`](9.x/Import-EsxConfigBaseline.ps1) |
| Advanced settings baseline and per-host deviation | #9 Config drift (NTP/DNS/syslog/lockdown) | Read | [`Export-EsxAdvancedSetting.ps1`](5.x/Export-EsxAdvancedSetting.ps1) | [`Export-EsxAdvancedSetting.ps1`](9.x/Export-EsxAdvancedSetting.ps1) |
| Apply an advanced settings baseline to hosts that drifted | #9 Config drift (NTP/DNS/syslog/lockdown) | Write | [`Import-EsxAdvancedSetting.ps1`](5.x/Import-EsxAdvancedSetting.ps1) | [`Import-EsxAdvancedSetting.ps1`](9.x/Import-EsxAdvancedSetting.ps1) |
| Service state and firewall rule exceptions per host | #9 Config drift (NTP/DNS/syslog/lockdown) | Read | [`Export-EsxServiceAndFirewall.ps1`](5.x/Export-EsxServiceAndFirewall.ps1) | [`Export-EsxServiceAndFirewall.ps1`](9.x/Export-EsxServiceAndFirewall.ps1) |
| Hardware sensor and health alarm state per host | #6 Firmware/driver vs HCL compliance | Read | [`Export-EsxHardwareHealth.ps1`](5.x/Export-EsxHardwareHealth.ps1) | [`Export-EsxHardwareHealth.ps1`](9.x/Export-EsxHardwareHealth.ps1) |
| Coredump, scratch and persistent log location per host | #9 Config drift (NTP/DNS/syslog/lockdown) | Read | [`Export-EsxCoredumpAndLogConfig.ps1`](5.x/Export-EsxCoredumpAndLogConfig.ps1) | [`Export-EsxCoredumpAndLogConfig.ps1`](9.x/Export-EsxCoredumpAndLogConfig.ps1) |
| Point logs and dumps at persistent storage | #9 Config drift (NTP/DNS/syslog/lockdown) | Write | [`Invoke-EsxLogConfigRemediation.ps1`](5.x/Invoke-EsxLogConfigRemediation.ps1) | [`Invoke-EsxLogConfigRemediation.ps1`](9.x/Invoke-EsxLogConfigRemediation.ps1) |
| Host certificate subject, issuer and expiry | #1 Certificate expiry across the stack | Read | [`Export-EsxCertificate.ps1`](5.x/Export-EsxCertificate.ps1) | [`Export-EsxCertificate.ps1`](9.x/Export-EsxCertificate.ps1) |

## A note on cmdlet names

Driver and firmware detail comes from the per-host esxcli interface via Get-EsxCli -V2, which is the only place it is exposed. That call is per host and not fast; on a large estate expect these scripts to take minutes rather than seconds.

Back to the [repository index](../../README.md).
