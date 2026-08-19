# VCF 5.x to 9.x product name mapping

VCF 9.0 renamed most of the suite. The folders in this repository use the 9.x name; this
is the map back. Several products carry a third name from before the Aria rebrand, which
is still what most search results use.

| Folder | Pre-Aria name | VCF 5.x name | VCF 9.x name |
|---|---|---|---|
| [`vcf-installer`](../products/vcf-installer/) | - | Cloud Builder | VCF Installer |
| [`sddc-manager`](../products/sddc-manager/) | SDDC Manager | SDDC Manager | SDDC Manager |
| [`vcenter`](../products/vcenter/) | vCenter Server | vCenter Server | vCenter |
| [`esx`](../products/esx/) | ESXi | ESXi | ESX |
| [`vsan`](../products/vsan/) | Virtual SAN | vSAN | vSAN (ESA and OSA) |
| [`nsx`](../products/nsx/) | NSX-T Data Center | NSX-T Data Center | NSX (including vDefend) |
| [`vcf-operations`](../products/vcf-operations/) | vRealize Operations | Aria Operations | VCF Operations |
| [`vcf-operations-fleet-management`](../products/vcf-operations-fleet-management/) | vRealize Suite Lifecycle Manager | Aria Suite Lifecycle | VCF Operations fleet management |
| [`vcf-operations-for-logs`](../products/vcf-operations-for-logs/) | vRealize Log Insight | Aria Operations for Logs | VCF Operations for logs |
| [`vcf-operations-for-networks`](../products/vcf-operations-for-networks/) | vRealize Network Insight | Aria Operations for Networks | VCF Operations for networks |
| [`vcf-operations-orchestrator`](../products/vcf-operations-orchestrator/) | vRealize Orchestrator | Aria Automation Orchestrator | VCF Operations orchestrator |
| [`vcf-operations-hcx`](../products/vcf-operations-hcx/) | HCX | HCX | VCF Operations HCX |
| [`vcf-automation`](../products/vcf-automation/) | vRealize Automation | Aria Automation | VCF Automation |
| [`vsphere-supervisor`](../products/vsphere-supervisor/) | vSphere with Kubernetes | vSphere with Tanzu (Supervisor and TKG) | vSphere Supervisor and VKS |
| [`vcf-identity-broker`](../products/vcf-identity-broker/) | VMware Identity Manager | Workspace ONE Access | VCF Identity Broker |

## Why the folders are not split by name

Splitting the repository by product name would put the same use case in two unrelated
places purely because marketing changed. The product is the stable thing; the name and
the API surface are what move. So the folder is the product, and the version folder
inside it carries whatever that generation actually calls it and however its API works.

Back to the [repository index](../README.md).
