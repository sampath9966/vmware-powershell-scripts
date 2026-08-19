# VCF Operations HCX

A migration wave is a spreadsheet until somebody types it into the HCX UI one VM at a time, and its status is a progress bar that cannot be exported to the people asking about it. These scripts turn the wave into a file you build the migrations from, and the status into a table you can send.

| | Product name |
|---|---|
| VCF 5.x | HCX |
| VCF 9.x | VCF Operations HCX |

> The product was renamed between generations. The scripts are split by the VCF
> release they target, not by the product name, so start from the version folder
> that matches your environment.

## Version folders

- [`5.x/`](5.x/) - 7 scripts for VCF 5.x
- [`9.x/`](9.x/) - 7 scripts for VCF 9.x

## Use cases

| Use case | Pain area | Mode | 5.x | 9.x |
|---|---|---|---|---|
| Site pairings and service mesh layout | #10 Cross-domain inventory | Read | [`Export-HcxSitePairing.ps1`](5.x/Export-HcxSitePairing.ps1) | [`Export-HcxSitePairing.ps1`](9.x/Export-HcxSitePairing.ps1) |
| Every migration and where it has got to | #10 Cross-domain inventory | Read | [`Export-HcxMigrationStatus.ps1`](5.x/Export-HcxMigrationStatus.ps1) | [`Export-HcxMigrationStatus.ps1`](9.x/Export-HcxMigrationStatus.ps1) |
| Build a whole migration wave from a spreadsheet | #10 Cross-domain inventory, #16 Config portability between environments | Write | [`Import-HcxMigrationWave.ps1`](5.x/Import-HcxMigrationWave.ps1) | [`Import-HcxMigrationWave.ps1`](9.x/Import-HcxMigrationWave.ps1) |
| Extended networks and their health | #10 Cross-domain inventory, #9 Config drift (NTP/DNS/syslog/lockdown) | Read | [`Export-HcxNetworkExtension.ps1`](5.x/Export-HcxNetworkExtension.ps1) | [`Export-HcxNetworkExtension.ps1`](9.x/Export-HcxNetworkExtension.ps1) |
| Compute and network profile definitions | #16 Config portability between environments | Read | [`Export-HcxComputeProfile.ps1`](5.x/Export-HcxComputeProfile.ps1) | [`Export-HcxComputeProfile.ps1`](9.x/Export-HcxComputeProfile.ps1) |
| Interconnect appliance state and tunnel health | #9 Config drift (NTP/DNS/syslog/lockdown) | Read | [`Export-HcxApplianceHealth.ps1`](5.x/Export-HcxApplianceHealth.ps1) | [`Export-HcxApplianceHealth.ps1`](9.x/Export-HcxApplianceHealth.ps1) |
| Re-run validation on pending migrations | #10 Cross-domain inventory | Read | [`Export-HcxMigrationValidation.ps1`](5.x/Export-HcxMigrationValidation.ps1) | [`Export-HcxMigrationValidation.ps1`](9.x/Export-HcxMigrationValidation.ps1) |

## A note on cmdlet names

Uses the VMware.VimAutomation.Hcx cmdlets against the source-side HCX Manager. Migration creation is deliberately split from starting it: Import-HcxMigrationWave.ps1 validates and creates, and only starts the migrations when you explicitly ask it to.

Back to the [repository index](../../README.md).
