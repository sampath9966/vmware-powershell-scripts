# Aria Operations for Logs - VCF 5.x

PowerCLI scripts for Aria Operations for Logs as shipped in VMware Cloud Foundation 5.x.

Every script is standalone: copy any single `.ps1` out of this folder and it runs on
its own. Nothing here dot-sources a shared helper.

| Script | Use case | Mode | Pain area | Modules |
|---|---|---|---|---|
| [`Export-LogsSourceCoverage.ps1`](Export-LogsSourceCoverage.ps1) | Which sources have gone quiet, and which never started | Read | #9, #15 | `(REST via Invoke-RestMethod)` |
| [`Export-LogsContentPack.ps1`](Export-LogsContentPack.ps1) | Content pack inventory and version state | Read | #16 | `(REST via Invoke-RestMethod)` |
| [`Import-LogsContentPack.ps1`](Import-LogsContentPack.ps1) | Install the content packs another instance already has | Write | #16 | `(REST via Invoke-RestMethod)` |
| [`Export-LogsAlertQuery.ps1`](Export-LogsAlertQuery.ps1) | Alert queries and where they notify | Read | #13, #16 | `(REST via Invoke-RestMethod)` |
| [`Export-LogsAgentGroup.ps1`](Export-LogsAgentGroup.ps1) | Agent groups and their collection configuration | Read | #9, #16 | `(REST via Invoke-RestMethod)` |
| [`Import-LogsAgentGroup.ps1`](Import-LogsAgentGroup.ps1) | Push agent group configuration into another instance | Write | #9, #16 | `(REST via Invoke-RestMethod)` |
| [`Export-LogsForwarder.ps1`](Export-LogsForwarder.ps1) | Forwarding destinations and their health | Read | #9, #16 | `(REST via Invoke-RestMethod)` |

## Export / import round trips

These pairs share an export envelope. The export writes it, the write-side script
validates it before changing anything, so the two always agree on the shape.

| Envelope schema | Export | Applies it |
|---|---|---|
| `logs.agent-group` | [`Export-LogsAgentGroup.ps1`](Export-LogsAgentGroup.ps1) | [`Import-LogsAgentGroup.ps1`](Import-LogsAgentGroup.ps1) |
| `logs.content-pack` | [`Export-LogsContentPack.ps1`](Export-LogsContentPack.ps1) | [`Import-LogsContentPack.ps1`](Import-LogsContentPack.ps1) |

## Safety

Scripts marked **Write** change the target. They all support `-DiffOnly` to print the
plan and stop, and `-WhatIf` / `-Confirm` through `SupportsShouldProcess`. Run any of
them with `-DiffOnly` first.

Back to [Aria Operations for Logs](../README.md) | [repository index](../../../README.md)
