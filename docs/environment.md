# Phase 3: environment and Checkout Reliability Lab

The environment stack uses the bootstrap-owned resource group in West US 3.
It never declares that group, the deployment identity, the state container, or
the externally owned state account as managed resources.

## Architecture and ownership

| Object | Owner / plane | Identity and permissions | Repeat behavior |
| --- | --- | --- | --- |
| Monitoring UAMI | Environment Terraform / ARM | Operator initially; CI RG Contributor subsequently | Updates the same identity |
| Log Analytics workspace | Environment Terraform / ARM through AzAPI | Local authentication disabled; no shared-key lookup | Retains the same workspace and 30-day retention |
| SRE Agent | Environment Terraform / ARM through AzAPI | UAMI for low-access, review-mode actions and RG discovery | Updates the same agent; no data-plane assets managed |
| Monitoring grants | Environment Terraform / ARM | UAMI: Reader on target RG, Log Analytics Reader on workspace | Deterministic role-assignment IDs |
| Agent administrator grants | Environment Terraform / ARM | Operator and deployment UAMI, agent scope only | Deterministic role-assignment IDs |
| Container Apps environment and private worker | Environment Terraform / ARM through AzAPI | No application identity or credentials needed | Single active revision; one small replica |
| Console/system log routing | Environment Terraform / ARM | Azure Monitor diagnostic settings to this workspace | Same named setting; no workspace key |
| Optional CI RBAC delegation | Bootstrap Terraform / ARM | Conditioned RBAC Administrator at target RG | Operator manages; CI cannot broaden or delete its own delegation |
| Skills, custom agents and scheduled task | Phase 4 PowerShell / data plane | See [data-plane.md](data-plane.md) | No Terraform double ownership |

The worker runs the versioned Python source directly from the ARM container
command, using a digest-pinned official Python image. It needs no image build,
registry credentials, storage account, public ingress, customer data or payment
service. This intentionally small synthetic scenario logs one event every ten
seconds. Durations and payment outcomes are synthetic, not measured calls to
a dependency. It is not a production checkout API or a load test.

The agent's system-assigned identity is platform-required but receives no
monitoring grants here. The UAMI is explicitly selected in both
`actionConfiguration` and `knowledgeGraphConfiguration`. Connector features
that require another identity need separate Phase 4 contract review, not
automatic broadening of either identity.

## Prerequisites and first deployment

Complete [bootstrap.md](bootstrap.md), including successful main-only hosted
verification. Use the same selected target subscription and tenant. Verify
`Microsoft.App`, `Microsoft.ManagedIdentity`, `Microsoft.OperationalInsights`,
`Microsoft.Insights` and `Microsoft.Authorization` are registered. Providers do
not register themselves or alter Azure Policy.

The interactive operator needs resource deployment and role-assignment write
permissions in the target RG. Initial deployment is operator-run because the
Phase 2 CI Contributor grant cannot assign roles. Subsequent CI permission is
established separately below, and automated `main`-branch delivery is documented
in [delivery.md](delivery.md).

Run from the root in Windows PowerShell 5.1 or `pwsh`, checking every native
exit code. Do not set client secrets, certificates, account keys, SAS tokens,
Terraform CLI-argument overrides, or debug token logging.

```powershell
. .\scripts\Common.ps1
Assert-KeylessEnvironment
$account = Invoke-NativeJson az @('account', 'show', '-o', 'json')
if ($account.user.type -ne 'user' -or $account.environmentName -ne 'AzureCloud') {
    throw 'Select an interactive AzureCloud account.'
}
$env:TF_VAR_target_subscription_id = $account.id
$env:TF_VAR_tenant_id = $account.tenantId
$env:TF_VAR_operator_object_id = Invoke-Native az @('ad', 'signed-in-user', 'show', '--query', 'id', '-o', 'tsv')

.\scripts\Initialize-Backend.ps1 -StorageAccountName <supplied-account> -ContainerName sre-checkout -StateKey checkout.tfstate -Authentication AzureCli
Invoke-Native terraform @('-chdir=infra\environment', 'plan', '-input=false', '-lock-timeout=60s', '-out=environment.tfplan')
# Review the plan before applying exactly that file.
Invoke-Native terraform @('-chdir=infra\environment', 'apply', '-input=false', 'environment.tfplan')
Remove-Item -LiteralPath .\infra\environment\environment.tfplan
Invoke-Native terraform @('-chdir=infra\environment', 'plan', '-input=false', '-detailed-exitcode')
```

The last command must return zero, not Terraform's exit code 2 for changes.
Keep local settings, plans and state out of Git and Actions artifacts. Outputs
are only resource/identity IDs, the workspace customer ID and the agent
endpoint, never credentials. The workspace uses AzAPI specifically to avoid
the shared-key exports of a workspace provider resource. There is no
Application Insights instrumentation key or workspace key in this deployment.

The pinned agent API is `2026-01-01`, which the pinned AzAPI provider validates.
Container Apps uses `2025-07-01`; the workspace uses `2025-07-01`. These versions
were checked against provider-advertised West US 3 availability and primary
schema documentation. An advertised region and a valid plan are not proof of
successful provisioning; see live evidence below.

## Establish constrained CI role-assignment permission

After the first successful operator environment apply:

```powershell
$monitoringPrincipal = Invoke-Native terraform @('-chdir=infra\environment', 'output', '-raw', 'monitoring_principal_id')
.\scripts\Bootstrap.ps1 -StateStorageAccountId <supplied-account-arm-id> -MonitoringPrincipalId $monitoringPrincipal -Apply
```

This adds one bootstrap-owned assignment, not a second owner for environment
grants. Its condition permits Reader and Log Analytics Reader only for the
exact monitoring principal, and SRE Agent Administrator only for the exact
deployment and operator principals. Both write and delete are conditioned,
and scope is limited to the target RG and its descendants. CI cannot grant
Owner, Contributor or RBAC Administrator, assign another principal, or manage
the delegation itself. State remains separately container-scoped.

The wrapper preserves the configured monitoring principal on later bootstrap
runs without that parameter. If the monitoring identity is intentionally
replaced, the operator must refresh this delegation with its new principal
before CI can manage replacement role assignments. Do not weaken the
condition or introduce bootstrap apply into CI to avoid that handoff.

## Telemetry and controlled fault

Healthy behavior is the default. To inject a synthetic payment timeout in
every fifth event, create and review another saved plan with
`-var=fault_enabled=true`, then apply that plan. To recover, repeat with
`-var=fault_enabled=false`. The setting is an environment input, not a public
HTTP fault endpoint. Always include the intended setting in later plans:
command-line variable values are not persisted configuration.

In the deployed workspace, query:

```kusto
ContainerAppConsoleLogs
| where TimeGenerated > ago(30m)
| where ContainerAppName == "ca-sre-checkout"
| extend checkout = parse_json(Log)
| where tostring(checkout.service) == "checkout"
| project TimeGenerated, RevisionName,
          order_id=tostring(checkout.order_id),
          status=tostring(checkout.status),
          error_code=tostring(checkout.error_code),
          fault_enabled=tobool(checkout.fault_enabled),
          duration_ms=toint(checkout.duration_ms)
| order by TimeGenerated desc
```

Allow for initial workspace/table creation and ingestion latency. A query
before the first logs arrive can report a missing table; it is not evidence
that logging works. Verify healthy events, controlled failure events with
`PAYMENT_PROVIDER_TIMEOUT`, then healthy events from the recovery revision.
Synthetic order IDs restart per process, so correlate them with revision,
timestamp and container context rather than treating them as globally unique.
This Azure Monitor diagnostic route writes the resource-specific table above;
do not use the older `ContainerAppConsoleLogs_CL` direct-workspace table.

Use the operator's Entra identity to query the workspace or the Azure portal;
never retrieve workspace keys. Check the monitoring UAMI role assignments
separately. Operator query success alone does not prove a query by that UAMI;
agent-executed query evidence must be recorded explicitly.

## Failures, recovery, cost and retirement

Terraform errors fail the run. Rerun a freshly reviewed plan after fixing the
specific problem; a partial apply is not a successful environment. Existing
unmanaged objects require ownership verification and explicit import, not
imperative overwrite or a second stack. Use the failed resource's exact ARM ID
with `terraform import`, then review the next plan.

The worker keeps one 0.25-vCPU / 0.5-GiB consumption replica alive. Log retention
is 30 days with a 1-GB daily workspace cap; ingestion can stop at the cap.
SRE Agent and supporting resources can incur charges while deployed. This
example is not a cost estimate or a production availability design.

Retire environment resources through an explicitly reviewed environment
destroy plan, never RG deletion. Bootstrap retirement is separate and
protected. Preserve needed state/history; never delete or reconfigure the
shared state account, its resource group, or unrelated containers and blobs.

## Verification evidence

Static evidence: provider-backed schema validation and Python unit tests cover
healthy traffic, deterministic injected failures, recovery and invalid fault
settings. The bootstrap mock verifies that the explicit monitoring principal
survives repeat invocation. These are not live-agent query evidence.

Live evidence recorded **November 16, 2026**:

- The previous merge's hosted bootstrap run `43915056852` succeeded.
- The environment applied ten resources in the existing West US 3 RG; no
  bootstrap-owned object or shared account setting changed. Agent provisioning
  succeeded, and the worker reported `Running`.
- A second environment plan exposed that Azure does not retain the diagnostic
  setting's `Dedicated` destination option. Removing that unsupported option
  produced a zero-change plan without ignoring drift.
- Workspace local authentication was verified disabled. Entra queries returned
  45 initial healthy events, 26 successful and six deliberately failed events
  from fault revision `--0000001`, and 158 healthy recovery events from revision
  `--0000002` at the verification snapshot. These counts grow as traffic runs.
  Failures contained `PAYMENT_PROVIDER_TIMEOUT`; recovery had the switch off.
- Agent thread `c628a639-3d7a-42cd-9705-58f3b8e2c90a` executed
  `az monitor log-analytics query` through `RunAzCliReadCommands` and returned
  11 actual healthy records during initial ingestion. A subsequent
  `az account show` in the agent sandbox reported
  `userAssignedIdentity` / `servicePrincipal` in the expected subscription.
  ARM explicitly selects the monitoring identity, the only attached UAMI;
  that UAMI has exactly RG Reader and workspace Log Analytics Reader.
  No token was retrieved or decoded to attribute its claims.
- The local selected-CLI identity authenticated to the agent's
  `/api/v1/threads` endpoint with the documented `https://azuresre.dev`
  audience and received HTTP 200. The MCP server's different signed-in
  identity was denied at subscription lookup; no permissions were added to
  accommodate that identity.
- The optional conditioned CI delegation applied as one bootstrap addition.
  Bootstrap's next plan and the environment's final post-recovery plan both
  returned exit code zero with no changes.

The worker is left **healthy**, with `fault_enabled=false`. Initial ingestion
took several minutes; missing-table and empty-result responses were not
counted as success. The agent's early query preceded fault-record ingestion;
fault/recovery workspace evidence above came from the local operator query.
Subsequent Phase 4 data-plane asset reconciliation, Phase 5 hosted OIDC
deployment (`deploy.yml`, run `43942955764`), and the Phase 6 live fault
investigation (`c63b8c97-fac0-42c9-958a-cdca00609ee5`) are documented in
[data-plane.md](data-plane.md), [delivery.md](delivery.md), and
[demonstration.md](demonstration.md).

## Primary contracts

- [Agent ARM schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.app/2026-01-01/agents)
  and [SRE Agent IaC](https://learn.microsoft.com/en-us/azure/sre-agent/deploy-iac).
- [Managed environment ARM schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.app/2025-07-01/managedenvironments)
  and [Azure Monitor log routing](https://learn.microsoft.com/en-us/azure/container-apps/log-options).
- [Workspace ARM schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.operationalinsights/2025-07-01/workspaces).
- [Conditioned RBAC delegation](https://learn.microsoft.com/en-us/azure/role-based-access-control/delegate-role-assignments-examples).
