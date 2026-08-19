# VCF Operations for networks

Networks is the only thing in the stack that can tell you which VM actually talks to which VM, on which port - which is the input a microsegmentation project needs and the thing people end up screenshotting one flow at a time. These scripts pull the flow data, the application model and the data source health out as tables.

| | Product name |
|---|---|
| VCF 5.x | Aria Operations for Networks |
| VCF 9.x | VCF Operations for networks |

> The product was renamed between generations. The scripts are split by the VCF
> release they target, not by the product name, so start from the version folder
> that matches your environment.

## Version folders

- [`5.x/`](5.x/) - 7 scripts for VCF 5.x
- [`9.x/`](9.x/) - 7 scripts for VCF 9.x

## Use cases

| Use case | Pain area | Mode | 5.x | 9.x |
|---|---|---|---|---|
| Data source inventory and collection health | #9 Config drift (NTP/DNS/syslog/lockdown) | Read | [`Export-NetworksDataSource.ps1`](5.x/Export-NetworksDataSource.ps1) | [`Export-NetworksDataSource.ps1`](9.x/Export-NetworksDataSource.ps1) |
| Add data sources in bulk from a file | #16 Config portability between environments | Write | [`Import-NetworksDataSource.ps1`](5.x/Import-NetworksDataSource.ps1) | [`Import-NetworksDataSource.ps1`](9.x/Import-NetworksDataSource.ps1) |
| VM-to-VM flows for firewall rule planning | #8 DFW rules and effective membership | Read | [`Export-NetworksVmFlow.ps1`](5.x/Export-NetworksVmFlow.ps1) | [`Export-NetworksVmFlow.ps1`](9.x/Export-NetworksVmFlow.ps1) |
| Application definitions and their tier membership | #16 Config portability between environments, #10 Cross-domain inventory | Read | [`Export-NetworksApplication.ps1`](5.x/Export-NetworksApplication.ps1) | [`Export-NetworksApplication.ps1`](9.x/Export-NetworksApplication.ps1) |
| Recreate the application model elsewhere | #16 Config portability between environments | Write | [`Import-NetworksApplication.ps1`](5.x/Import-NetworksApplication.ps1) | [`Import-NetworksApplication.ps1`](9.x/Import-NetworksApplication.ps1) |
| Alert and problem definitions currently configured | #13 Alarm noise and audit-trail extraction | Read | [`Export-NetworksAlertDefinition.ps1`](5.x/Export-NetworksAlertDefinition.ps1) | [`Export-NetworksAlertDefinition.ps1`](9.x/Export-NetworksAlertDefinition.ps1) |
| The network path between two VMs, hop by hop | #10 Cross-domain inventory | Read | [`Export-NetworksVmPath.ps1`](5.x/Export-NetworksVmPath.ps1) | [`Export-NetworksVmPath.ps1`](9.x/Export-NetworksVmPath.ps1) |

## A note on cmdlet names

Calls the /api/ni interface with a token from /api/ni/auth/token. Flow queries go through the search endpoint, which is rate-limited on large environments - the flow script pages deliberately and slowly for that reason.

Back to the [repository index](../../README.md).
