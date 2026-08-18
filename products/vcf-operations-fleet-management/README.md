# VCF Operations fleet management

Fleet management is where the lockers live - certificates and passwords for every product it manages - and where the record of which product is on which version actually sits. All of it is UI-only. These scripts pull the lockers and the environment inventory out as tables, and let a certificate or a datacenter registration be pushed back in.

| | Product name |
|---|---|
| VCF 5.x | Aria Suite Lifecycle |
| VCF 9.x | VCF Operations fleet management |

> The product was renamed between generations. The scripts are split by the VCF
> release they target, not by the product name, so start from the version folder
> that matches your environment.

## Version folders

- [`5.x/`](5.x/) - 8 scripts for VCF 5.x
- [`9.x/`](9.x/) - 8 scripts for VCF 9.x

## Use cases

| Use case | Pain area | Mode | 5.x | 9.x |
|---|---|---|---|---|
| Which product is on which version, in which environment | #3 BOM / version drift per domain | Read | [`Export-FleetEnvironmentInventory.ps1`](5.x/Export-FleetEnvironmentInventory.ps1) | [`Export-FleetEnvironmentInventory.ps1`](9.x/Export-FleetEnvironmentInventory.ps1) |
| Certificate locker contents and expiry | #1 Certificate expiry across the stack | Read | [`Export-FleetCertificateLocker.ps1`](5.x/Export-FleetCertificateLocker.ps1) | [`Export-FleetCertificateLocker.ps1`](9.x/Export-FleetCertificateLocker.ps1) |
| Load renewed certificates into the locker | #1 Certificate expiry across the stack | Write | [`Import-FleetCertificateLocker.ps1`](5.x/Import-FleetCertificateLocker.ps1) | [`Import-FleetCertificateLocker.ps1`](9.x/Import-FleetCertificateLocker.ps1) |
| Password locker metadata without the secrets | #2 Credential rotation and expiry | Read | [`Export-FleetPasswordLocker.ps1`](5.x/Export-FleetPasswordLocker.ps1) | [`Export-FleetPasswordLocker.ps1`](9.x/Export-FleetPasswordLocker.ps1) |
| Which install and upgrade binaries are actually staged | #12 Upgrade prechecks and bundle state | Read | [`Export-FleetProductBinary.ps1`](5.x/Export-FleetProductBinary.ps1) | [`Export-FleetProductBinary.ps1`](9.x/Export-FleetProductBinary.ps1) |
| Request and task history with the failures picked out | #12 Upgrade prechecks and bundle state, #13 Alarm noise and audit-trail extraction | Read | [`Export-FleetRequestHistory.ps1`](5.x/Export-FleetRequestHistory.ps1) | [`Export-FleetRequestHistory.ps1`](9.x/Export-FleetRequestHistory.ps1) |
| Datacenter and vCenter registration record | #16 Config portability between environments | Read | [`Export-FleetDataCenterRegistration.ps1`](5.x/Export-FleetDataCenterRegistration.ps1) | [`Export-FleetDataCenterRegistration.ps1`](9.x/Export-FleetDataCenterRegistration.ps1) |
| Recreate datacenter and vCenter registrations | #16 Config portability between environments | Write | [`Import-FleetDataCenterRegistration.ps1`](5.x/Import-FleetDataCenterRegistration.ps1) | [`Import-FleetDataCenterRegistration.ps1`](9.x/Import-FleetDataCenterRegistration.ps1) |

## A note on cmdlet names

Calls the appliance API under /lcm/... with basic authentication. Locker exports never include secret material - passwords come back as metadata only, and certificate exports carry the public certificate and its expiry, never the private key.

Back to the [repository index](../../README.md).
