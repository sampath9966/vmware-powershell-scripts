# VCF Operations - VCF 9.x

PowerCLI scripts for VCF Operations as shipped in VMware Cloud Foundation 9.x.

Every script is standalone: copy any single `.ps1` out of this folder and it runs on
its own. Nothing here dot-sources a shared helper.

| Script | Use case | Mode | Pain area | Modules |
|---|---|---|---|---|
| [`Export-OpsRightsizingRecommendation.ps1`](Export-OpsRightsizingRecommendation.ps1) | Oversized, undersized and idle VMs with the numbers behind it | Read | #14 | `VMware.VimAutomation.vROps` |
| [`Export-OpsActiveAlert.ps1`](Export-OpsActiveAlert.ps1) | Active alerts with the definition and object behind each | Read | #13 | `VMware.VimAutomation.vROps` |
| [`Export-OpsAlertDefinition.ps1`](Export-OpsAlertDefinition.ps1) | Alert and symptom definitions as a portable file | Read | #13, #16 | `(REST via Invoke-RestMethod)` |
| [`Import-OpsAlertDefinition.ps1`](Import-OpsAlertDefinition.ps1) | Push alert definitions into another Operations instance | Write | #13, #16 | `(REST via Invoke-RestMethod)` |
| [`Export-OpsCustomGroup.ps1`](Export-OpsCustomGroup.ps1) | Custom groups and their membership rules | Read | #16, #10 | `(REST via Invoke-RestMethod)` |
| [`Export-OpsAdapterHealth.ps1`](Export-OpsAdapterHealth.ps1) | Adapter and collector state - what has stopped collecting | Read | #9 | `(REST via Invoke-RestMethod)` |
| [`Export-OpsMetricSeries.ps1`](Export-OpsMetricSeries.ps1) | Bulk metric pull for a set of resources | Read | #14 | `VMware.VimAutomation.vROps` |
| [`Export-OpsNotificationRule.ps1`](Export-OpsNotificationRule.ps1) | Notification rules and where alerts are being sent | Read | #13, #16 | `(REST via Invoke-RestMethod)` |

## Export / import round trips

These pairs share an export envelope. The export writes it, the write-side script
validates it before changing anything, so the two always agree on the shape.

| Envelope schema | Export | Applies it |
|---|---|---|
| `vcf-operations.alert-definition` | [`Export-OpsAlertDefinition.ps1`](Export-OpsAlertDefinition.ps1) | [`Import-OpsAlertDefinition.ps1`](Import-OpsAlertDefinition.ps1) |

## Safety

Scripts marked **Write** change the target. They all support `-DiffOnly` to print the
plan and stop, and `-WhatIf` / `-Confirm` through `SupportsShouldProcess`. Run any of
them with `-DiffOnly` first.

Back to [VCF Operations](../README.md) | [repository index](../../../README.md)
