# VCF Operations

Operations knows the answer to most capacity and rightsizing questions, and shows them in views that cannot be scheduled out in a usable shape. It is also where a lot of hand-built content lives - dashboards, alert definitions, policies, custom groups - which exists in exactly one place until someone exports it. These scripts do both: pull the analysis out as data, and make the content portable.

| | Product name |
|---|---|
| VCF 5.x | Aria Operations |
| VCF 9.x | VCF Operations |

> The product was renamed between generations. The scripts are split by the VCF
> release they target, not by the product name, so start from the version folder
> that matches your environment.

## Version folders

- [`5.x/`](5.x/) - 8 scripts for VCF 5.x
- [`9.x/`](9.x/) - 8 scripts for VCF 9.x

## Use cases

| Use case | Pain area | Mode | 5.x | 9.x |
|---|---|---|---|---|
| Oversized, undersized and idle VMs with the numbers behind it | #14 Rightsizing and idle workloads | Read | [`Export-OpsRightsizingRecommendation.ps1`](5.x/Export-OpsRightsizingRecommendation.ps1) | [`Export-OpsRightsizingRecommendation.ps1`](9.x/Export-OpsRightsizingRecommendation.ps1) |
| Active alerts with the definition and object behind each | #13 Alarm noise and audit-trail extraction | Read | [`Export-OpsActiveAlert.ps1`](5.x/Export-OpsActiveAlert.ps1) | [`Export-OpsActiveAlert.ps1`](9.x/Export-OpsActiveAlert.ps1) |
| Alert and symptom definitions as a portable file | #13 Alarm noise and audit-trail extraction, #16 Config portability between environments | Read | [`Export-OpsAlertDefinition.ps1`](5.x/Export-OpsAlertDefinition.ps1) | [`Export-OpsAlertDefinition.ps1`](9.x/Export-OpsAlertDefinition.ps1) |
| Push alert definitions into another Operations instance | #13 Alarm noise and audit-trail extraction, #16 Config portability between environments | Write | [`Import-OpsAlertDefinition.ps1`](5.x/Import-OpsAlertDefinition.ps1) | [`Import-OpsAlertDefinition.ps1`](9.x/Import-OpsAlertDefinition.ps1) |
| Custom groups and their membership rules | #16 Config portability between environments, #10 Cross-domain inventory | Read | [`Export-OpsCustomGroup.ps1`](5.x/Export-OpsCustomGroup.ps1) | [`Export-OpsCustomGroup.ps1`](9.x/Export-OpsCustomGroup.ps1) |
| Adapter and collector state - what has stopped collecting | #9 Config drift (NTP/DNS/syslog/lockdown) | Read | [`Export-OpsAdapterHealth.ps1`](5.x/Export-OpsAdapterHealth.ps1) | [`Export-OpsAdapterHealth.ps1`](9.x/Export-OpsAdapterHealth.ps1) |
| Bulk metric pull for a set of resources | #14 Rightsizing and idle workloads | Read | [`Export-OpsMetricSeries.ps1`](5.x/Export-OpsMetricSeries.ps1) | [`Export-OpsMetricSeries.ps1`](9.x/Export-OpsMetricSeries.ps1) |
| Notification rules and where alerts are being sent | #13 Alarm noise and audit-trail extraction, #16 Config portability between environments | Read | [`Export-OpsNotificationRule.ps1`](5.x/Export-OpsNotificationRule.ps1) | [`Export-OpsNotificationRule.ps1`](9.x/Export-OpsNotificationRule.ps1) |

## A note on cmdlet names

Most scripts here call the Suite API at /suite-api/api/... directly with Invoke-RestMethod, because there is no cmdlet for that surface. Dashboard content sits on the internal API path and is called out in the help of the script that uses it - treat that one as version-sensitive. A few scripts use the VMware.VimAutomation.vROps cmdlets where they cover the job properly.

Back to the [repository index](../../README.md).
