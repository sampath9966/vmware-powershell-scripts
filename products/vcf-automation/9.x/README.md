# VCF Automation - VCF 9.x

PowerCLI scripts for VCF Automation as shipped in VMware Cloud Foundation 9.x.

Every script is standalone: copy any single `.ps1` out of this folder and it runs on
its own. Nothing here dot-sources a shared helper.

| Script | Use case | Mode | Pain area | Modules |
|---|---|---|---|---|
| [`Export-AutomationDeploymentInventory.ps1`](Export-AutomationDeploymentInventory.ps1) | Every deployment with owner, project, lease and cost | Read | #10, #5 | `(REST via Invoke-RestMethod)` |
| [`Invoke-AutomationDeploymentExpiry.ps1`](Invoke-AutomationDeploymentExpiry.ps1) | Expire or destroy reviewed idle deployments | Write | #5, #14 | `(REST via Invoke-RestMethod)` |
| [`Export-AutomationCloudTemplate.ps1`](Export-AutomationCloudTemplate.ps1) | Cloud templates with their YAML and version history | Read | #16 | `(REST via Invoke-RestMethod)` |
| [`Import-AutomationCloudTemplate.ps1`](Import-AutomationCloudTemplate.ps1) | Push cloud templates into another Automation instance | Write | #16 | `(REST via Invoke-RestMethod)` |
| [`Export-AutomationProject.ps1`](Export-AutomationProject.ps1) | Projects, membership and their cloud zone bindings | Read | #16, #10 | `(REST via Invoke-RestMethod)` |
| [`Import-AutomationProject.ps1`](Import-AutomationProject.ps1) | Recreate projects and their membership | Write | #16 | `(REST via Invoke-RestMethod)` |
| [`Export-AutomationCloudZoneMapping.ps1`](Export-AutomationCloudZoneMapping.ps1) | Cloud zones, flavor and image mappings | Read | #16 | `(REST via Invoke-RestMethod)` |
| [`Export-AutomationRequestFailure.ps1`](Export-AutomationRequestFailure.ps1) | Provisioning request failures with the actual error | Read | #13 | `(REST via Invoke-RestMethod)` |

## Export / import round trips

These pairs share an export envelope. The export writes it, the write-side script
validates it before changing anything, so the two always agree on the shape.

| Envelope schema | Export | Applies it |
|---|---|---|
| `automation.cloud-template` | [`Export-AutomationCloudTemplate.ps1`](Export-AutomationCloudTemplate.ps1) | [`Import-AutomationCloudTemplate.ps1`](Import-AutomationCloudTemplate.ps1) |
| `automation.deployment-inventory` | [`Export-AutomationDeploymentInventory.ps1`](Export-AutomationDeploymentInventory.ps1) | [`Invoke-AutomationDeploymentExpiry.ps1`](Invoke-AutomationDeploymentExpiry.ps1) |
| `automation.project` | [`Export-AutomationProject.ps1`](Export-AutomationProject.ps1) | [`Import-AutomationProject.ps1`](Import-AutomationProject.ps1) |

## Safety

Scripts marked **Write** change the target. They all support `-DiffOnly` to print the
plan and stop, and `-WhatIf` / `-Confirm` through `SupportsShouldProcess`. Run any of
them with `-DiffOnly` first.

Back to [VCF Automation](../README.md) | [repository index](../../../README.md)
