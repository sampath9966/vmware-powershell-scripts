# Connection patterns

Seven ways to reach a VCF product from PowerShell. Every script in this repository uses
one of them, and each product README says which. Picking the wrong one is the usual reason
a script stops working after an upgrade, so this page is about the trade-offs rather than
the syntax.

---

## 1. VimAutomation cmdlets

**Reaches** vCenter, ESX, vSAN, distributed switches, storage policies.

```powershell
$connection = Connect-VIServer -Server $Server -Credential $Credential
try   { Get-VM | Select-Object Name, PowerState }
finally { Disconnect-VIServer -Server $connection -Confirm:$false }
```

The most stable surface in the whole stack. Cmdlets that worked on vSphere 6.5 largely
still work today. **Always the first choice** when a cmdlet exists.

Used by: `vcenter`, `esx`, `vsan`, `vsphere-supervisor`.

---

## 2. Get-View and the vSphere Management API

**Reaches** the managed object properties no cmdlet surfaces.

```powershell
$healthSystem = Get-View -Id $vmHost.ExtensionData.ConfigManager.HealthStatusSystem
$healthSystem.Runtime.SystemHealthInfo.NumericSensorInfo
```

Faster than cmdlets on large inventories, because it fetches only the properties asked
for. The cost is that it returns raw managed objects with no PowerShell ergonomics, and
the property names change between API versions with no deprecation warning.

Used for hardware sensors, the certificate manager, licence assignment, and consolidation
state - none of which have cmdlets.

---

## 3. Get-EsxCli -V2

**Reaches** a single ESX host, directly.

```powershell
$esxcli = Get-EsxCli -VMHost $vmHost -V2
$arguments = $esxcli.system.module.get.CreateArgs()
$arguments.module = 'nmlx5_core'
$esxcli.system.module.get.Invoke($arguments)
```

The only route to driver versions, firmware versions, coredump configuration and syslog
reload. Always use `-V2`; the v1 interface is positional and breaks silently when a
parameter is added.

One round trip per host and not fast - scripts using it say so in their help.

---

## 4. Get-CisService and the vSphere Automation API

**Reaches** vCenter services that live outside the Management API, notably Supervisor.

```powershell
$cisConnection = Connect-CisServer -Server $Server -Credential $Credential
$namespaces = Get-CisService -Name 'com.vmware.vcenter.namespaces.instances'
$namespaces.list()
```

Request bodies are built with the service's own `Help` object rather than hashtables:

```powershell
$spec = $namespaces.Help.create.spec.Create()
$spec.cluster = $clusterId
```

`Connect-CisServer` is a separate connection from `Connect-VIServer`, even to the same
vCenter. Scripts needing both open both and close both.

Used by: `vsphere-supervisor`.

---

## 5. Generated SDK modules

**Reaches** SDDC Manager, VCF Installer, Cloud Builder, the NSX Policy API.

```powershell
Connect-VcfSddcManagerServer -Server $Server -User $user -Password $password
$domains = Invoke-VcfGetDomains

$credential = Initialize-VcfBaseCredential -Username 'root'
$resource   = Initialize-VcfResourceCredentials -ResourceType 'ESXI' -Credentials $credential
$spec       = Initialize-VcfCredentialsUpdateSpec -OperationType 'ROTATE' -Elements @($resource)
Invoke-VcfUpdateOrRotatePasswords -CredentialsUpdateSpec $spec
```

Generated from each product's OpenAPI specification, so coverage is complete - if the API
can do it, there is a cmdlet. The trade-off is that **cmdlet names track operation ids and
do shift between builds**. When a name does not resolve, list the current set:

```powershell
Get-VcfSddcManagerOperation -Path '*/v1/domains' -Method Get
```

Every script in this repository that uses an SDK module names the REST path it calls, so
the route back to the API reference is short.

Used by: `sddc-manager`, `vcf-installer`.

---

## 6. NSX service proxies

**Reaches** everything in NSX. There are no first-class NSX cmdlets beyond connect and
disconnect.

```powershell
$connection = Connect-NsxtServer -Server $Server -Credential $Credential

# Policy API - declarative, the modern surface
$policies = Get-NsxtPolicyService -Name 'com.vmware.nsx_policy.infra.domains.security_policies'
$policies.list('default').results

# Manager API - imperative, still the only route to fabric objects
$transportNodes = Get-NsxtService -Name 'com.vmware.nsx.transport_nodes'
$transportNodes.list().results
```

Both are needed. The Policy API covers firewall rules, groups, segments and gateways; the
Manager API covers transport nodes, the fabric VM inventory, VM tags and certificates.

Objects are built from the service's `Help` tree, the same pattern as `Get-CisService`:

```powershell
$spec = $rules.Help.patch.rule.Create()
$spec.display_name = 'allow-web'
```

Paths returned by the Policy API are paths, not names. Resolving
`/infra/domains/default/groups/web-tier` to `web-tier` is left to the caller, which is
most of what the NSX scripts here actually do.

Used by: `nsx`.

---

## 7. Invoke-RestMethod with a token

**Reaches** every product with no cmdlet surface at all.

```powershell
$body = @{ username = $Credential.UserName
           password = $Credential.GetNetworkCredential().Password } | ConvertTo-Json

$auth = Invoke-RestMethod -Method Post -ContentType 'application/json' `
    -Uri "https://$Server/suite-api/api/auth/token/acquire" -Body $body

$headers = @{ Accept = 'application/json'; Authorization = "vRealizeOpsToken $($auth.token)" }
```

The authentication shape differs per product:

| Product | Token endpoint | Header |
|---|---|---|
| VCF Operations | `/suite-api/api/auth/token/acquire` | `vRealizeOpsToken <token>` |
| Operations for logs | `/api/v2/sessions` | `Bearer <sessionId>` |
| Operations for networks | `/api/ni/auth/token` | `NetworkInsight <token>` |
| VCF Automation | `/csp/gateway/am/api/login` then `/iaas/api/login` | `Bearer <token>` |
| Identity Broker | `/SAAS/API/1.0/REST/auth/system/login` | `HZN <sessionToken>` |
| Fleet management | basic authentication | `Basic <base64>` |
| Orchestrator | basic authentication | `Basic <base64>` |

### Certificate validation

PowerShell 7 has `-SkipCertificateCheck`. Windows PowerShell 5.1 does not, and needs the
callback instead. Scripts here handle both, and warn when validation is disabled:

```powershell
if ($PSVersionTable.PSVersion.Major -ge 6) {
    $restCommon['SkipCertificateCheck'] = $true
}
else {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
}
```

The 5.1 callback is process-wide and stays set for the rest of the session. That is a real
downside, which is why it is behind an opt-in switch documented as lab-only.

Used by: `vcf-operations`, `vcf-operations-fleet-management`, `vcf-operations-for-logs`,
`vcf-operations-for-networks`, `vcf-operations-orchestrator`, `vcf-automation`,
`vcf-identity-broker`.

---

## Choosing

1. Is there a cmdlet? Use it.
2. Is the property on a managed object? `Get-View`.
3. Is it host-local? `Get-EsxCli -V2`.
4. Is it a vCenter service outside the Management API? `Get-CisService`.
5. Does the product ship an SDK module? Use it, and record the REST path in the help.
6. Is it NSX? Service proxies, and resolve paths to names before returning anything.
7. Otherwise `Invoke-RestMethod`, and put the endpoint in the `.DESCRIPTION`.

Back to the [repository index](../README.md).
