# VCF PowerCLI Use-Case Library

PowerCLI for the questions VMware Cloud Foundation makes hard to answer.

Every product in the VCF Bill of Materials gets a folder. Every folder is split by VCF
generation. Every use case is one `.ps1` that runs on its own.

| | |
|---|---|
| Products covered | 15 |
| Use cases | 125 (90 read, 35 write) |
| Scripts | 250, across `5.x/` and `9.x/` |
| Dependencies | PowerCLI only - no community modules |

---

## Why this exists

Most VCF automation writing is a list of one-liners. That is not where the time goes.

The time goes into questions the product can technically answer but will not collate: which
certificate in the whole estate expires first, which host drifted off the NTP standard, which
VM is really in which NSX security group, which deployment has an owner who left. The data is
there. It is behind a per-domain view with no export, or a tree that has to be expanded one
node at a time, or an API that returns a policy path where a human needs a name.

Every use case here starts from one of those, and the recurring ones are numbered:

| # | Pain area | Why it hurts |
|---|---|---|
| 1 | **Certificate expiry across the stack** | Certificates live in vCenter, ESX, NSX, SDDC Manager, the lockers and Identity Broker. No single view. An expired one cascades - an expired Avi certificate blocks password rotation entirely. |
| 2 | **Credential rotation and expiry** | Rotation is per component and error-prone at scale. An expired password puts a whole domain into an error state. |
| 3 | **BOM / version drift per domain** | Which component is on which version, per workload domain, against the release BOM. Lives in three places at once. |
| 4 | **Snapshot sprawl** | Age, size, orphaned deltas, consolidation-needed - and the UI shows snapshots one VM at a time. |
| 5 | **Orphaned and zombie assets** | Unregistered VMDKs, orphaned VMs, stale templates, deployments nobody has touched in a year. Nothing looks for them. |
| 6 | **Firmware/driver vs HCL compliance** | Driver and firmware per adapter per host, cross-checked to the compatibility guide. esxcli gives it one host at a time. |
| 7 | **Licensing and core counts** | Per-cluster physical core counts for core-based licensing. No screen adds them up. |
| 8 | **DFW rules and effective membership** | Which VM is really in which group, and which rules actually apply. Effective membership is paged, per group. |
| 9 | **Config drift (NTP/DNS/syslog/lockdown)** | NTP, DNS, syslog, lockdown, agent config, sync schedules. Divergence is silent until it matters. |
| 10 | **Cross-domain inventory** | 'Which VM, on which host, in which domain, with which tag, in which namespace' needs several tools and a spreadsheet. |
| 11 | **vSAN health, capacity, policy compliance** | Resync state, non-compliant objects, slack space. Per cluster, in a view that does not export. |
| 12 | **Upgrade prechecks and bundle state** | What is staged, what is applicable, what will block the upgrade. Answered by clicking every tile. |
| 13 | **Alarm noise and audit-trail extraction** | Exporting who did what, and what is actually firing often enough to matter. |
| 14 | **Rightsizing and idle workloads** | Rightsizing needs metric history joined to inventory. The reclamation view rounds it and will not export. |
| 15 | **Protection gaps** | VMs and namespaces with no backup, no replication, no protection group. The gap is invisible by definition. |
| 16 | **Config portability between environments** | Dashboards, policies, tags, firewall rules, templates rebuilt by hand in dev and DR because nothing exports them. |

---

## Products

Folders are named for the VCF 9.x product. The 5.x name is in the table because the renaming
between generations is itself a thing people lose time to.

| Product | VCF 5.x name | Use cases | Scripts |
|---|---|---|---|
| [**VCF Installer**](products/vcf-installer/) | Cloud Builder | 7 | 14 |
| [**SDDC Manager**](products/sddc-manager/) | SDDC Manager | 13 | 26 |
| [**vCenter**](products/vcenter/) | vCenter Server | 13 | 26 |
| [**ESX**](products/esx/) | ESXi | 10 | 20 |
| [**vSAN (ESA and OSA)**](products/vsan/) | vSAN | 7 | 14 |
| [**NSX (including vDefend)**](products/nsx/) | NSX-T Data Center | 9 | 18 |
| [**VCF Operations**](products/vcf-operations/) | Aria Operations | 8 | 16 |
| [**VCF Operations fleet management**](products/vcf-operations-fleet-management/) | Aria Suite Lifecycle | 8 | 16 |
| [**VCF Operations for logs**](products/vcf-operations-for-logs/) | Aria Operations for Logs | 7 | 14 |
| [**VCF Operations for networks**](products/vcf-operations-for-networks/) | Aria Operations for Networks | 7 | 14 |
| [**VCF Operations orchestrator**](products/vcf-operations-orchestrator/) | Aria Automation Orchestrator | 7 | 14 |
| [**VCF Operations HCX**](products/vcf-operations-hcx/) | HCX | 7 | 14 |
| [**VCF Automation**](products/vcf-automation/) | Aria Automation | 8 | 16 |
| [**vSphere Supervisor and VKS**](products/vsphere-supervisor/) | vSphere with Tanzu (Supervisor and TKG) | 7 | 14 |
| [**VCF Identity Broker**](products/vcf-identity-broker/) | Workspace ONE Access | 7 | 14 |

Full rename map, including the products that changed name twice:
[`docs/product-name-mapping.md`](docs/product-name-mapping.md).

---

## Getting started

```powershell
Install-Module VMware.PowerCLI -Scope CurrentUser

$cred = Get-Credential

# Read something. Nothing is written unless you pass -OutputPath.
./products/sddc-manager/5.x/Export-SddcCertificateInventory.ps1 `
    -Server sddc.example.local -Credential $cred -ExpiringInDays 90

# Same thing, into the envelope that the matching write script accepts.
./products/sddc-manager/5.x/Export-SddcCertificateInventory.ps1 `
    -Server sddc.example.local -Credential $cred -ExpiringInDays 90 `
    -OutputPath ./certs.json -Format JSON

# Plan the change. -DiffOnly never touches anything.
./products/sddc-manager/5.x/Invoke-SddcCertificateRenewal.ps1 `
    -Server sddc.example.local -Credential $cred -InputPath ./certs.json -DiffOnly

# Apply it, one resource at a time.
./products/sddc-manager/5.x/Invoke-SddcCertificateRenewal.ps1 `
    -Server sddc.example.local -Credential $cred -InputPath ./certs.json -Confirm
```

Every script carries full comment-based help:

```powershell
Get-Help ./products/nsx/9.x/Export-NsxDfwRule.ps1 -Full
```

---

## How a use case is built

There is no single way to reach VCF from PowerShell, and picking the wrong one is why so many
scripts stop working after an upgrade. Seven approaches are used here, each where it fits:

| # | Approach | Reaches | Used for |
|---|---|---|---|
| 1 | `VMware.VimAutomation.*` cmdlets | vCenter, ESX, vSAN, vDS, SPBM | Anything with a real cmdlet. Always the first choice. |
| 2 | `Get-View` / vSphere Management API | vCenter internals | Properties no cmdlet surfaces - health sensors, certificate manager, licence assignment. |
| 3 | `Get-EsxCli -V2` | A single ESX host | Driver and firmware detail, coredump config, syslog reload. The only route to some of it. |
| 4 | `Get-CisService` / vSphere Automation API | vCenter, Supervisor | Namespace management, VM classes, tagging internals. |
| 5 | Generated SDK modules (`VMware.Sdk.Vcf.*`, `VMware.Sdk.Nsx.Policy`) | SDDC Manager, Installer, Cloud Builder, NSX policy | Whole-API coverage with `Initialize-*` builders for request bodies. |
| 6 | `Get-NsxtPolicyService` / `Get-NsxtService` proxies | NSX Policy and Manager APIs | Everything NSX. There are no first-class NSX cmdlets beyond connect. |
| 7 | `Invoke-RestMethod` with a token | Operations, Logs, Networks, Orchestrator, Automation, fleet management, Identity Broker | Products with no cmdlet surface at all. |

Each approach, with the authentication shape and the trade-offs:
[`docs/connection-patterns.md`](docs/connection-patterns.md).

---

## The script contract

**Every `.ps1` here runs standalone.** No shared module, no dot-sourcing, no repository layout
assumptions. Copy one file onto a jump box and it works. The duplication is deliberate.

**Read scripts** (`Export-*`, `Get-*Report`) emit objects to the pipeline and write nothing
unless you pass `-OutputPath`. `-Format CSV|JSON|HTML` picks the shape.

**Write scripts** (`Import-*`, `Invoke-*`, `Set-*`) consume the JSON envelope a read script
produced, validate it, print a plan, and gate every change:

```json
{ "schema": "vcf.sddc.certificate-inventory", "schemaVersion": "1.0",
  "product": "sddc-manager", "vcfVersion": "5.x",
  "exportedOn": "...", "sourceServer": "...", "recordCount": 42,
  "data": [ ... ] }
```

A write script refuses a file whose `schema` or `product` does not match, and warns on a
`vcfVersion` mismatch. Then:

- `-DiffOnly` prints the plan - Create, Update, Remove or Match per item - and exits.
- `-WhatIf` and `-Confirm` work throughout, via `SupportsShouldProcess` with a high confirm impact.
- Items already in the desired state come back as `Match` and are left alone, so re-running is safe.
- Destructive scripts re-verify against live state first, so a stale file cannot delete something in use.

Full contract, including what a contributed script has to satisfy:
[`CONTRIBUTING.md`](CONTRIBUTING.md).

---

## What has and has not been verified

Being straight about this matters more than the scripts looking finished.

**Verified:** all 250 scripts parse cleanly under the PowerShell language parser;
`Invoke-ScriptAnalyzer -Severity Error,Warning` is clean across the whole tree; comment-based
help renders for every script; every write script declares `SupportsShouldProcess`; no script
dot-sources another file; every script is listed in its folder README.

**Not verified:** none of this has been executed against a live VCF instance. API property
names and generated SDK cmdlet names follow the documented interface for each product, but
generated cmdlet names track operation ids and do shift between builds. Each product README
names the REST paths and says how to list the current cmdlet set on your own appliance.

**So:** run `-DiffOnly` first, on every write script, every time. That is what it is for.

---

## Licence

Apache 2.0. See [`LICENSE`](LICENSE).

Author: **Sampath**
