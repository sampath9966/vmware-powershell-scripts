# VCF Operations for logs

The most useful question you can ask a log platform is which sources have stopped sending - and that is exactly the one the UI cannot answer, because a source that went quiet has no events to show. These scripts answer it by diffing what is sending against what should be, and make the hand-built content (content packs, alert queries, agent groups) portable.

| | Product name |
|---|---|
| VCF 5.x | Aria Operations for Logs |
| VCF 9.x | VCF Operations for logs |

> The product was renamed between generations. The scripts are split by the VCF
> release they target, not by the product name, so start from the version folder
> that matches your environment.

## Version folders

- [`5.x/`](5.x/) - 7 scripts for VCF 5.x
- [`9.x/`](9.x/) - 7 scripts for VCF 9.x

## Use cases

| Use case | Pain area | Mode | 5.x | 9.x |
|---|---|---|---|---|
| Which sources have gone quiet, and which never started | #9 Config drift (NTP/DNS/syslog/lockdown), #15 Protection gaps | Read | [`Export-LogsSourceCoverage.ps1`](5.x/Export-LogsSourceCoverage.ps1) | [`Export-LogsSourceCoverage.ps1`](9.x/Export-LogsSourceCoverage.ps1) |
| Content pack inventory and version state | #16 Config portability between environments | Read | [`Export-LogsContentPack.ps1`](5.x/Export-LogsContentPack.ps1) | [`Export-LogsContentPack.ps1`](9.x/Export-LogsContentPack.ps1) |
| Install the content packs another instance already has | #16 Config portability between environments | Write | [`Import-LogsContentPack.ps1`](5.x/Import-LogsContentPack.ps1) | [`Import-LogsContentPack.ps1`](9.x/Import-LogsContentPack.ps1) |
| Alert queries and where they notify | #13 Alarm noise and audit-trail extraction, #16 Config portability between environments | Read | [`Export-LogsAlertQuery.ps1`](5.x/Export-LogsAlertQuery.ps1) | [`Export-LogsAlertQuery.ps1`](9.x/Export-LogsAlertQuery.ps1) |
| Agent groups and their collection configuration | #9 Config drift (NTP/DNS/syslog/lockdown), #16 Config portability between environments | Read | [`Export-LogsAgentGroup.ps1`](5.x/Export-LogsAgentGroup.ps1) | [`Export-LogsAgentGroup.ps1`](9.x/Export-LogsAgentGroup.ps1) |
| Push agent group configuration into another instance | #9 Config drift (NTP/DNS/syslog/lockdown), #16 Config portability between environments | Write | [`Import-LogsAgentGroup.ps1`](5.x/Import-LogsAgentGroup.ps1) | [`Import-LogsAgentGroup.ps1`](9.x/Import-LogsAgentGroup.ps1) |
| Forwarding destinations and their health | #9 Config drift (NTP/DNS/syslog/lockdown), #16 Config portability between environments | Read | [`Export-LogsForwarder.ps1`](5.x/Export-LogsForwarder.ps1) | [`Export-LogsForwarder.ps1`](9.x/Export-LogsForwarder.ps1) |

## A note on cmdlet names

Calls the /api/v2 interface with a session token acquired from /api/v2/sessions. Session tokens are short-lived by design, so each script authenticates for its own run.

Back to the [repository index](../../README.md).
