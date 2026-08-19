# Aria Automation Orchestrator - VCF 5.x

PowerCLI scripts for Aria Automation Orchestrator as shipped in VMware Cloud Foundation 5.x.

Every script is standalone: copy any single `.ps1` out of this folder and it runs on
its own. Nothing here dot-sources a shared helper.

| Script | Use case | Mode | Pain area | Modules |
|---|---|---|---|---|
| [`Export-OrchestratorWorkflow.ps1`](Export-OrchestratorWorkflow.ps1) | Workflow inventory with version and last run | Read | #16, #13 | `(REST via Invoke-RestMethod)` |
| [`Export-OrchestratorRunHistory.ps1`](Export-OrchestratorRunHistory.ps1) | Execution history with the failures picked out | Read | #13 | `(REST via Invoke-RestMethod)` |
| [`Export-OrchestratorConfigurationElement.ps1`](Export-OrchestratorConfigurationElement.ps1) | Configuration elements - the endpoints everything depends on | Read | #16 | `(REST via Invoke-RestMethod)` |
| [`Import-OrchestratorConfigurationElement.ps1`](Import-OrchestratorConfigurationElement.ps1) | Replay configuration element values into another orchestrator | Write | #16 | `(REST via Invoke-RestMethod)` |
| [`Export-OrchestratorScheduledTask.ps1`](Export-OrchestratorScheduledTask.ps1) | Scheduled tasks and whether they are still succeeding | Read | #13 | `(REST via Invoke-RestMethod)` |
| [`Export-OrchestratorPackage.ps1`](Export-OrchestratorPackage.ps1) | Package inventory and the content each one carries | Read | #16 | `(REST via Invoke-RestMethod)` |
| [`Import-OrchestratorPackage.ps1`](Import-OrchestratorPackage.ps1) | Install packages the target does not have | Write | #16 | `(REST via Invoke-RestMethod)` |

## Export / import round trips

These pairs share an export envelope. The export writes it, the write-side script
validates it before changing anything, so the two always agree on the shape.

| Envelope schema | Export | Applies it |
|---|---|---|
| `orchestrator.configuration-element` | [`Export-OrchestratorConfigurationElement.ps1`](Export-OrchestratorConfigurationElement.ps1) | [`Import-OrchestratorConfigurationElement.ps1`](Import-OrchestratorConfigurationElement.ps1) |
| `orchestrator.package` | [`Export-OrchestratorPackage.ps1`](Export-OrchestratorPackage.ps1) | [`Import-OrchestratorPackage.ps1`](Import-OrchestratorPackage.ps1) |

## Safety

Scripts marked **Write** change the target. They all support `-DiffOnly` to print the
plan and stop, and `-WhatIf` / `-Confirm` through `SupportsShouldProcess`. Run any of
them with `-DiffOnly` first.

Back to [Aria Automation Orchestrator](../README.md) | [repository index](../../../README.md)
