# VCF Identity Broker

Identity is the component everything else authenticates against and nobody documents. Which directory is connected, which identity provider is actually in use, which groups sync and which quietly stopped, and who holds an administrative role - these scripts pull all of it out, and make the access policy portable.

| | Product name |
|---|---|
| VCF 5.x | Workspace ONE Access |
| VCF 9.x | VCF Identity Broker |

> The product was renamed between generations. The scripts are split by the VCF
> release they target, not by the product name, so start from the version folder
> that matches your environment.

## Version folders

- [`5.x/`](5.x/) - 7 scripts for VCF 5.x
- [`9.x/`](9.x/) - 7 scripts for VCF 9.x

## Use cases

| Use case | Pain area | Mode | 5.x | 9.x |
|---|---|---|---|---|
| Identity providers and the authentication methods each offers | #16 Config portability between environments | Read | [`Export-IdentityProvider.ps1`](5.x/Export-IdentityProvider.ps1) | [`Export-IdentityProvider.ps1`](9.x/Export-IdentityProvider.ps1) |
| Directory connections and their sync configuration | #16 Config portability between environments, #9 Config drift (NTP/DNS/syslog/lockdown) | Read | [`Export-IdentityDirectoryConfig.ps1`](5.x/Export-IdentityDirectoryConfig.ps1) | [`Export-IdentityDirectoryConfig.ps1`](9.x/Export-IdentityDirectoryConfig.ps1) |
| Directory sync drift - what stopped syncing and when | #9 Config drift (NTP/DNS/syslog/lockdown) | Read | [`Export-IdentitySyncStatus.ps1`](5.x/Export-IdentitySyncStatus.ps1) | [`Export-IdentitySyncStatus.ps1`](9.x/Export-IdentitySyncStatus.ps1) |
| Access policies and their authentication rules | #16 Config portability between environments | Read | [`Export-IdentityAccessPolicy.ps1`](5.x/Export-IdentityAccessPolicy.ps1) | [`Export-IdentityAccessPolicy.ps1`](9.x/Export-IdentityAccessPolicy.ps1) |
| Replay an access policy into another instance | #16 Config portability between environments | Write | [`Import-IdentityAccessPolicy.ps1`](5.x/Import-IdentityAccessPolicy.ps1) | [`Import-IdentityAccessPolicy.ps1`](9.x/Import-IdentityAccessPolicy.ps1) |
| Who holds an administrative role | #13 Alarm noise and audit-trail extraction | Read | [`Export-IdentityRoleAssignment.ps1`](5.x/Export-IdentityRoleAssignment.ps1) | [`Export-IdentityRoleAssignment.ps1`](9.x/Export-IdentityRoleAssignment.ps1) |
| Login and administrative audit trail | #13 Alarm noise and audit-trail extraction | Read | [`Export-IdentityAuditEvent.ps1`](5.x/Export-IdentityAuditEvent.ps1) | [`Export-IdentityAuditEvent.ps1`](9.x/Export-IdentityAuditEvent.ps1) |

## A note on cmdlet names

Authenticates at /SAAS/API/1.0/REST/auth/system/login and calls the management API under /SAAS/jersey/manager/api/... Several of these endpoints need an administrator role, not just a valid session, so a read that returns empty usually means insufficient privilege rather than no data.

Back to the [repository index](../../README.md).
