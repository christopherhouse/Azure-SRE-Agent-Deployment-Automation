# Phase 6: demonstration and operator handoff

This guide walks an operator through the complete **Checkout Reliability Lab**
lifecycle: prerequisites, one-time bootstrap, local and GitHub Actions
deployment, controlled fault injection, Log Analytics verification, live Azure
SRE Agent investigation, scheduled-task automation, troubleshooting, cost
drivers, and safe cleanup that preserves the externally owned state storage
account.

## What is automated vs. manual or excluded

| Capability | Status | Mechanism and identity boundary |
| --- | --- | --- |
| Target resource group, deployment UAMI, OIDC federation, and dedicated state container | Automated (operator bootstrap) | `scripts/Bootstrap.ps1` + `infra/bootstrap` using interactive Azure CLI and GitHub CLI (`gh`) |
| Shared state storage account (`satfstatecmhcus`) | External prerequisite | Never declared, reconfigured, or deleted by Terraform or PowerShell; accessed only via container-scoped Entra Blob RBAC |
| SRE Agent, Log Analytics workspace, monitoring UAMI, Container Apps workload, and RBAC | Automated (local or `main` CI) | `scripts/Deploy-Environment.ps1` + `infra/environment` using Entra Blob state auth and Azure CLI locally or GitHub OIDC in `.github/workflows/deploy.yml` |
| Investigation skill (`checkout-investigation`), subagent (`checkout-investigator`), and scheduled task (`checkout-daily-investigation`) | Automated (local or `main` CI) | `scripts/Deploy-Environment.ps1` -> `New-SreAgentAssetPackage` -> `scripts/Deploy-Assets.ps1` against the agent data plane (`https://azuresre.dev` audience) |
| Source context for `sample/checkout.py` | Automated snapshot + optional manual OAuth | `Deploy-Assets.ps1` bundles the version-controlled `sample/checkout.py` and its SHA-256 into `checkout-investigation`. Live GitHub repository reads require one-time interactive operator OAuth consent in the SRE Agent portal |
| Scheduled investigation trigger (`checkout-daily-investigation`) | Automated (reconciled `Paused` by default) | Reconciled via the SRE Agent v2 scheduled-tasks API (`Review` mode, cron `0 14 * * *` UTC). Can be resumed via the portal/API or set to `Active` in Git |
| External HTTP webhook / GitHub push trigger | Excluded by design | Current Microsoft documentation conflicts on whether external webhook routes are unauthenticated public URLs or require an Entra `AgentThreadWrite` bearer token, which GitHub webhooks cannot mint. No PAT, app private key, or public webhook URL is created |

## End-to-end reproduction quickstart

### 1. Prerequisites

1. Use AzureCloud and GitHub.com with Terraform **1.15.2**, Azure CLI (`az`),
   GitHub CLI (`gh`), Python 3.11+, and Windows PowerShell 5.1 or `pwsh`.
2. Sign in interactively and select the target deployment subscription:
   ```powershell
   az login
   az account set --subscription <target-subscription-id>
   gh auth login
   ```
3. Obtain the full ARM resource ID of the externally supplied Azure Storage
   account used for remote state (its subscription does not need to match the
   target deployment subscription, provided both share the same Entra tenant and
   allow Entra Blob authentication without Shared Key).

### 2. Bootstrap identity, state container, and GitHub variables

Run the bootstrap stack from the repository root (see [bootstrap.md](bootstrap.md)
for full details):

```powershell
$stateAccountId = '/subscriptions/<state-sub>/resourceGroups/<state-rg>/providers/Microsoft.Storage/storageAccounts/<account>'
.\scripts\Bootstrap.ps1 -StateStorageAccountId $stateAccountId -Apply -ConfigureGitHub
```

After merging bootstrap changes to `main`, confirm that the
`Verify keyless bootstrap` workflow (`verify-bootstrap.yml`) succeeds.

### 3. Deploy the environment and SRE Agent data-plane assets

Run the unified orchestrator locally in `pwsh` or Windows PowerShell 5.1:

```powershell
.\scripts\Deploy-Environment.ps1 `
    -StorageAccountName <account> `
    -ContainerName sre-checkout `
    -StateKey checkout.tfstate `
    -Authentication AzureCli
```

On the first operator deployment, record the monitoring UAMI principal ID and
establish the constrained CI RBAC delegation in the bootstrap stack so
subsequent GitHub Actions deployments on `main` can manage the environment's
deterministic role assignments:

```powershell
$monitoringPrincipal = terraform -chdir=infra\environment output -raw monitoring_principal_id
.\scripts\Bootstrap.ps1 `
    -StateStorageAccountId $stateAccountId `
    -MonitoringPrincipalId $monitoringPrincipal `
    -Apply `
    -ConfigureGitHub
```

From that point forward, every merge to `main` that touches `infra/environment/`,
`sample/`, `sre-agent/`, `scripts/`, or `.github/workflows/deploy.yml`
automatically runs **Deploy checkout environment** (`deploy.yml`) using GitHub
OIDC without a manual approval gate.

## Walkthrough: controlled checkout fault, investigation, and recovery

### Step 1: Inject the controlled checkout fault

Enable the synthetic payment-provider timeout on every fifth checkout event by
passing the `-FaultEnabled` switch to `Deploy-Environment.ps1`:

```powershell
.\scripts\Deploy-Environment.ps1 `
    -StorageAccountName <account> `
    -ContainerName sre-checkout `
    -StateKey checkout.tfstate `
    -Authentication AzureCli `
    -FaultEnabled
```

 Note: `-FaultEnabled` is a PowerShell `[switch]` parameter. Pass
`-FaultEnabled` (or `-FaultEnabled:$true`) to enable the fault, and omit
`-FaultEnabled` (or pass `-FaultEnabled:$false`) to restore healthy behavior.
Do not pass `-FaultEnabled $true` with a space, which binds `$true`
positionally.

Terraform updates only `azapi_resource.checkout` (`CHECKOUT_FAULT_ENABLED` from
`"false"` to `"true"`), creating a new Container App revision while leaving the
SRE Agent and all three data-plane assets unchanged.

### Step 2: Confirm fault telemetry in Log Analytics

Allow 2–4 minutes for Azure Monitor diagnostic settings to batch and ingest the
new revision's console logs into the resource-specific `ContainerAppConsoleLogs`
table (note: the resource-specific table uses column `Log`, not `Log_s`).
Verify with the operator's Entra identity:

```powershell
$workspaceCustomerId = terraform -chdir=infra\environment output -raw workspace_customer_id
$queryFile = Join-Path ([System.IO.Path]::GetTempPath()) "checkout-fault-query.json"
@{
    query = @"
ContainerAppConsoleLogs
| where TimeGenerated > ago(30m)
| where ContainerAppName == 'ca-sre-checkout'
| extend checkout = parse_json(Log)
| where tostring(checkout.service) == 'checkout'
| project TimeGenerated, RevisionName,
          order_id = tostring(checkout.order_id),
          status = tostring(checkout.status),
          error_code = tostring(checkout.error_code),
          fault_enabled = tobool(checkout.fault_enabled),
          duration_ms = toint(checkout.duration_ms)
| order by TimeGenerated desc
| take 15
"@
    timespan = "PT30M"
} | ConvertTo-Json -Compress | Set-Content -LiteralPath $queryFile -Encoding utf8

az rest --method POST `
    --url "https://api.loganalytics.io/v1/workspaces/$workspaceCustomerId/query" `
    --resource "https://api.loganalytics.io" `
    --headers "Content-Type=application/json" `
    --body "@$queryFile" `
    --query "tables[0].rows" -o json
Remove-Item -LiteralPath $queryFile -Force -ErrorAction SilentlyContinue
```

Every fifth synthetic order (`synthetic-00000005`, `synthetic-00000010`,
`synthetic-00000015`, ...) on the fault revision reports `status = "failed"`,
`error_code = "PAYMENT_PROVIDER_TIMEOUT"`, `fault_enabled = true`, and
`duration_ms = 3000`, while non-fifth orders report `status = "succeeded"` and
`duration_ms = 42`.

### Step 3: Run the SRE Agent investigation

In the Azure SRE Agent portal (or through the SRE Agent investigation API/MCP
tool), start a thread and prompt the agent:

> Use the `checkout-investigator` subagent and `checkout-investigation` skill
> to investigate `ca-sre-checkout` in `law-sre-checkout` over the last 30
> minutes. Compare revisions, correlate with the checkout source context, and
> recommend safe operator recovery without making any changes.

Verify that the agent response:

1. Queries `ContainerAppConsoleLogs` in `law-sre-checkout` using its monitoring
   managed identity (`RunAzCliReadCommands`).
2. Distinguishes the healthy revision (`fault_enabled = false`, `42 ms`) from
   the failing revision (`fault_enabled = true`, `PAYMENT_PROVIDER_TIMEOUT`,
   `3000 ms` on every fifth order, scoping `order_id` per revision/process).
3. Correlates the telemetry fields and `CHECKOUT_FAULT_ENABLED` toggle with
   `sample/checkout.py`, explicitly identifying whether it used the bundled
   source snapshot (including its SHA-256 hash) or a live OAuth GitHub read.
4. Recommends returning `fault_enabled` to `false` via operator deployment
   without performing write actions, calling webhooks, or creating issues/PRs.

### Step 4: Restore healthy traffic and verify convergence

Rerun `Deploy-Environment.ps1` without `-FaultEnabled`:

```powershell
.\scripts\Deploy-Environment.ps1 `
    -StorageAccountName <account> `
    -ContainerName sre-checkout `
    -StateKey checkout.tfstate `
    -Authentication AzureCli
```

Confirm that:

- Terraform updates `azapi_resource.checkout` back to
  `CHECKOUT_FAULT_ENABLED="false"` (`0 added, 1 changed, 0 destroyed`), creating
  a healthy recovery revision.
- After 2–4 minutes of ingestion, `ContainerAppConsoleLogs` shows fifth orders
  (such as `synthetic-00000005`, `synthetic-00000010`, `synthetic-00000025`) on
  the new revision succeeding in `42 ms` with `fault_enabled = false` and
  `error_code = null`.
- Running `Deploy-Environment.ps1` a second time reports
  `Apply complete! Resources: 0 added, 0 changed, 0 destroyed.` and `Unchanged`
  for all three data-plane assets.

## Live verification evidence (Phase 5 & Phase 6)

### Hosted CI/CD deployment on `main`

After the owner merged PR #6 (`ef75176`) to `main` on **November 16, 2026**:

- **Deploy checkout environment** (`.github/workflows/deploy.yml`, run
  `43942955764`) authenticated via GitHub OIDC (`id-sre-checkout-github`,
  subject
  `repo:christopherhouse@748998/Azure-SRE-Agent-Deployment-Automation@1457055905:ref:refs/heads/main`),
  initialized the Entra Blob backend (`satfstatecmhcus` / `sre-checkout` /
  `checkout.tfstate`), ran `terraform plan` and `terraform apply`
  (`0 added, 0 changed, 0 destroyed`), staged the deterministic checkout asset
  package (sample SHA-256
  `a4b166146fc5ffc8770c427418a3112e29ab22c058c53f42a44dc754344bf188`), and
  verified `Unchanged` across `skills/checkout-investigation`,
  `agents/checkout-investigator`, and
  `scheduledtasks/checkout-daily-investigation` in 43 seconds.
- **Verify keyless bootstrap** (`verify-bootstrap.yml`, run `43942955681`)
  serialized behind `deploy.yml` via the shared `sre-checkout-deployment`
  concurrency group and succeeded.

### Live fault injection, SRE Agent investigation, and recovery

Executed on **November 16, 2026** against `rg-sre-checkout-westus3` (agent
`sre-checkout-da3a0ee8`, workspace `5d427820-d3dd-4dca-b538-b8d1e4d36f4d`):

1. **Controlled fault injection**: Running `Deploy-Environment.ps1 ... -FaultEnabled`
   updated `azapi_resource.checkout` (`0 added, 1 changed, 0 destroyed`),
   activating revision `ca-sre-checkout--0000003` at `20:01:30Z`.
2. **Workspace telemetry verification**: `ContainerAppConsoleLogs` recorded
   `PAYMENT_PROVIDER_TIMEOUT` failures (`fault_enabled: true`,
   `status: "failed"`, `duration_ms: 3000`) on `ca-sre-checkout--0000003` for
   `synthetic-00000005` (`20:02:27.859Z`), `synthetic-00000010`
   (`20:03:17.861Z`), `synthetic-00000015` (`20:04:07.862Z`), and
   `synthetic-00000020` (`20:04:57.863Z`), with intervening orders succeeding in
   `42 ms`.
3. **Live SRE Agent investigation**: Investigation thread
   `c63b8c97-fac0-42c9-958a-cdca00609ee5` (`title: "Synthetic Checkout Telemetry Investigation"`,
   completed at `20:12:53Z`, message `da45c42d-f087-45d8-b1f1-a60407c342a0`)
   used `checkout-investigator` and `checkout-investigation` to:
   - Query `ContainerAppConsoleLogs` and contrast 11 healthy rows on
     `ca-sre-checkout--0000002` (`fault_enabled=False`, `42 ms`) against 20 rows
     on `ca-sre-checkout--0000003` (16 succeeded at `42 ms`, 4 failed with
     `PAYMENT_PROVIDER_TIMEOUT` at `3000 ms` on orders 5, 10, 15, and 20).
   - Cite the bundled `sample/checkout.py` snapshot (SHA-256
     `a4b166146fc5ffc8770c427418a3112e29ab22c058c53f42a44dc754344bf188`) and
     explicitly state that it used the stored skill snapshot rather than a live
     GitHub read.
   - Note Log Analytics ingestion lag after `20:04:57Z` as an explicit
     missing-data window rather than assuming recovery.
   - Recommend operator-only recovery (`fault_enabled=false`) with zero write
     actions.
4. **Scheduled-task lifecycle and drift reconciliation**: Scheduled task
   `checkout-daily-investigation` (`id: f0b0429f-b7d2-446c-88a7-a136781afc5b`)
   was resumed to `Active` via the SRE Agent scheduled-tasks API and then
   reconciled by `Deploy-Environment.ps1`, which detected the status drift and
   restored `Paused` (`Configured scheduledtasks/checkout-daily-investigation`).
   An immediate repeat run reported `0 added, 0 changed, 0 destroyed` and
   `Unchanged` for all three assets.
5. **Recovery and deliberate failure verification**: Running
   `Deploy-Environment.ps1` without `-FaultEnabled` created revision
   `ca-sre-checkout--0000004`, and `ContainerAppConsoleLogs` confirmed fifth
   orders (`synthetic-00000025` at `20:19:47.738Z`) succeeding in `42 ms` with
   `fault_enabled: false` and `error_code: null`. Setting `ARM_ACCESS_KEY` in a
   test process caused `Deploy-Environment.ps1` to fail immediately (`Remove
   ARM_ACCESS_KEY from this process before running the keyless bootstrap.`)
   before any backend or Azure API call.

## Troubleshooting

| Symptom | Cause | Resolution |
| --- | --- | --- |
| `ContainerAppConsoleLogs` query returns `Failed to resolve table or column` or zero rows immediately after deploy/fault toggle | Azure Monitor diagnostic setting creation and Log Analytics ingestion take ~2–4 minutes | Wait 2–4 minutes and retry; verify live container emission with `az containerapp logs show -n ca-sre-checkout -g rg-sre-checkout-westus3 --tail 20` |
| `Deploy-Environment.ps1` fails with `Cannot validate argument on parameter 'OperatorObjectId'` when toggling fault | Passing `-FaultEnabled $true` with a space binds `$true` positionally to `-OperatorObjectId` | Use `-FaultEnabled` (or `-FaultEnabled:$true`) to enable, and omit `-FaultEnabled` (or pass `-FaultEnabled:$false`) to disable |
| `Deploy-Assets.ps1` refuses an existing skill, subagent, or scheduled task | Object lacks `managed-by:checkout-reliability-lab` tag (or description suffix on scheduled tasks) | Inspect the object in the portal to confirm provenance; restore the marker or remove the conflicting unmanaged object before rerunning |
| Data-plane PUT returns HTTP 202 and read-back fails convergence | Service accepted the asynchronous write, or a preview property was dropped by the backend | Wait briefly and rerun `Deploy-Assets.ps1`; if convergence still fails, compare the GET payload against the corresponding manifest under `sre-agent/<kind>/<name>/` |
| Hosted `deploy.yml` fails on role assignment write/delete after monitoring UAMI replacement | Bootstrap conditioned RBAC delegation (`environment_rbac[0]`) is pinned to the previous monitoring principal ID | Run `.\scripts\Bootstrap.ps1 -StateStorageAccountId <id> -MonitoringPrincipalId <new-guid> -Apply` as the interactive operator |
| Azure CLI or MCP tool queries fail with tenant/subscription mismatch | Tool session is signed into a different Entra tenant than the target subscription | Pass `--tenant <AZURE_TENANT_ID>` or run `az login --tenant <AZURE_TENANT_ID>` and `az account set --subscription <AZURE_SUBSCRIPTION_ID>` |

## Cost drivers

While deployed, the lab incurs charges in the target subscription for:

- **Azure SRE Agent (`Microsoft.App/agents`)**: Billing depends on the preview
  pricing tier and active vs. paused scheduled runs. Keeping
  `checkout-daily-investigation` in `Paused` status avoids recurring daily
  investigation executions when the lab is idle.
- **Azure Container Apps (`ca-sre-checkout`)**: Runs a single `0.25` vCPU /
  `0.5` GiB replica (`minReplicas = 1`, `maxReplicas = 1`) on the Consumption
  workload profile so synthetic logs emit continuously every 10 seconds.
- **Azure Monitor Log Analytics (`law-sre-checkout`)**: Configured with a
  30-day retention period and a `1` GB daily ingestion cap (`PerGB2018`).
- **Remote state storage**: Uses a single small blob (`checkout.tfstate`) in
  the existing external storage account (`satfstatecmhcus`).

## Safe cleanup and retirement

Cleanup must **never** delete or reconfigure the externally owned state storage
account (`satfstatecmhcus`), its resource group (`rg-terraformstate`), its Blob
service settings, or any unrelated containers and blobs.

### 1. Retire the environment and SRE Agent resources (routine lab teardown)

Destroying the `infra/environment` stack removes the SRE Agent (along with its
nested data-plane skills, subagents, and scheduled tasks), the Container App
and managed environment, the Log Analytics workspace, the monitoring UAMI, and
the environment role assignments, while preserving the bootstrap identity,
target resource group, and remote state container for future redeployments:

```powershell
. .\scripts\Common.ps1
Assert-KeylessEnvironment
$account = Invoke-NativeJson az @('account', 'show', '-o', 'json')
$env:TF_VAR_target_subscription_id = $account.id
$env:TF_VAR_tenant_id = $account.tenantId
$env:TF_VAR_operator_object_id = Invoke-Native az @('ad', 'signed-in-user', 'show', '--query', 'id', '-o', 'tsv')

.\scripts\Initialize-Backend.ps1 `
    -StorageAccountName <account> `
    -ContainerName sre-checkout `
    -StateKey checkout.tfstate `
    -Authentication AzureCli

Invoke-Native terraform @('-chdir=infra\environment', 'plan', '-destroy', '-input=false', '-lock-timeout=60s', '-out=destroy.tfplan')
# Review the destroy plan to confirm only the 10 environment resources are targeted.
Invoke-Native terraform @('-chdir=infra\environment', 'apply', '-input=false', 'destroy.tfplan')
Remove-Item -LiteralPath .\infra\environment\destroy.tfplan -Force -ErrorAction SilentlyContinue
```

### 2. Optional full bootstrap retirement

If retiring the entire project permanently:

1. Complete Step 1 above so `checkout.tfstate` has zero managed environment
   resources.
2. Disable or remove the GitHub Actions workflows/variables (`AZURE_*` and
   `TF_STATE_*`) so CI does not attempt further OIDC logins.
3. In `infra/bootstrap/main.tf`, remove the `lifecycle { prevent_destroy = true }`
   blocks on `azurerm_resource_group.target`,
   `azurerm_user_assigned_identity.deployment`, and
   `azapi_resource.state_container` through an explicit reviewed change, then
   run `terraform -chdir=infra\bootstrap plan -destroy` and `apply`.
4. Verify that the external storage account (`satfstatecmhcus`) and all other
   containers in that account remain untouched.
