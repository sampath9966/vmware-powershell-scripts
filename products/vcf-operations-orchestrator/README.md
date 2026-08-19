# VCF Operations orchestrator

Orchestrator is where an organisation's automation logic actually lives, and it is almost always undocumented. Which workflows exist, which ones still run, which configuration elements hold the endpoints everything depends on, and which scheduled task has been failing quietly for months - these scripts answer all four as tables.

| | Product name |
|---|---|
| VCF 5.x | Aria Automation Orchestrator |
| VCF 9.x | VCF Operations orchestrator |

> The product was renamed between generations. The scripts are split by the VCF
> release they target, not by the product name, so start from the version folder
> that matches your environment.

## Version folders

- [`5.x/`](5.x/) - 7 scripts for VCF 5.x
- [`9.x/`](9.x/) - 7 scripts for VCF 9.x

## Use cases

| Use case | Pain area | Mode | 5.x | 9.x |
|---|---|---|---|---|
| Workflow inventory with version and last run | #16 Config portability between environments, #13 Alarm noise and audit-trail extraction | Read | [`Export-OrchestratorWorkflow.ps1`](5.x/Export-OrchestratorWorkflow.ps1) | [`Export-OrchestratorWorkflow.ps1`](9.x/Export-OrchestratorWorkflow.ps1) |
| Execution history with the failures picked out | #13 Alarm noise and audit-trail extraction | Read | [`Export-OrchestratorRunHistory.ps1`](5.x/Export-OrchestratorRunHistory.ps1) | [`Export-OrchestratorRunHistory.ps1`](9.x/Export-OrchestratorRunHistory.ps1) |
| Configuration elements - the endpoints everything depends on | #16 Config portability between environments | Read | [`Export-OrchestratorConfigurationElement.ps1`](5.x/Export-OrchestratorConfigurationElement.ps1) | [`Export-OrchestratorConfigurationElement.ps1`](9.x/Export-OrchestratorConfigurationElement.ps1) |
| Replay configuration element values into another orchestrator | #16 Config portability between environments | Write | [`Import-OrchestratorConfigurationElement.ps1`](5.x/Import-OrchestratorConfigurationElement.ps1) | [`Import-OrchestratorConfigurationElement.ps1`](9.x/Import-OrchestratorConfigurationElement.ps1) |
| Scheduled tasks and whether they are still succeeding | #13 Alarm noise and audit-trail extraction | Read | [`Export-OrchestratorScheduledTask.ps1`](5.x/Export-OrchestratorScheduledTask.ps1) | [`Export-OrchestratorScheduledTask.ps1`](9.x/Export-OrchestratorScheduledTask.ps1) |
| Package inventory and the content each one carries | #16 Config portability between environments | Read | [`Export-OrchestratorPackage.ps1`](5.x/Export-OrchestratorPackage.ps1) | [`Export-OrchestratorPackage.ps1`](9.x/Export-OrchestratorPackage.ps1) |
| Install packages the target does not have | #16 Config portability between environments | Write | [`Import-OrchestratorPackage.ps1`](5.x/Import-OrchestratorPackage.ps1) | [`Import-OrchestratorPackage.ps1`](9.x/Import-OrchestratorPackage.ps1) |

## A note on cmdlet names

Calls the /vco/api interface with basic authentication. Workflow and package content is exported as metadata plus, where asked for, the binary package file - the scripts never attempt to reconstruct workflow logic from JSON, because that does not round trip.

Back to the [repository index](../../README.md).
