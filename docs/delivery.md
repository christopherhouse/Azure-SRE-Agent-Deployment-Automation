# Phase 5: GitHub Actions delivery

Phase 5 connects the non-deploying PR checks from earlier phases to an automated,
trusted `main`-only deployment workflow (`.github/workflows/deploy.yml`) and a
shared PowerShell orchestrator (`scripts/Deploy-Environment.ps1`). Merging a
reviewed PR to `main` converges both the Terraform environment stack and the
PowerShell-owned SRE Agent data-plane assets without a manual approval gate.

## Workflow boundaries and concurrency

| Workflow | Triggers | Permissions & identity | Scope |
| --- | --- | --- | --- |
| `Repository checks` (`checks.yml`) | `pull_request` to `main`, `push` to `main`, `workflow_dispatch` | `contents: read`; no OIDC, secrets, or remote state | Cloud-free static validation (`actionlint`, `gitleaks`, `terraform fmt/validate`, PSScriptAnalyzer/Pester on `pwsh` and Windows PowerShell 5.1, Python unit tests) |
| `Verify keyless bootstrap` (`verify-bootstrap.yml`) | `push` to `main` (bootstrap paths only), `workflow_dispatch` on `main` | `contents: read`, `id-token: write` on job; federated deployment UAMI | ARM target RG check, non-state Blob lease probe, and OIDC backend initialization |
| `Deploy checkout environment` (`deploy.yml`) | `push` to `main` (environment, sample, asset, and delivery paths), `workflow_dispatch` on `main` | `contents: read`, `id-token: write` on job; federated deployment UAMI | End-to-end Terraform `plan`/`apply` plus packaged SRE Agent data-plane asset reconciliation |

Both `verify-bootstrap.yml` and `deploy.yml` share the concurrency group
`sre-checkout-deployment` with `cancel-in-progress: false` so Azure Blob state
locks and SRE Agent data-plane PUTs never overlap or abort mid-flight. Neither
workflow runs on `pull_request` or `pull_request_target`, and `Deploy-Environment.ps1`
additionally rejects non-`main` refs or pull-request events if invoked under
`GITHUB_ACTIONS=true`.

## Execution order and ownership contract

`scripts/Deploy-Environment.ps1` enforces a single deterministic sequence across
local (`-Authentication AzureCli`) and hosted (`-Authentication GitHubOidc`) runs:

1. **Keyless and caller guardrails**: Rejects forbidden credential/key
   environment variables (`Assert-KeylessEnvironment`), verifies interactive
   user login in `AzureCli` mode or trusted `refs/heads/main` service-principal
   context in `GitHubOidc` mode, and resolves the operator object ID (`az ad
   signed-in-user show` locally, or the non-secret `AZURE_OPERATOR_OBJECT_ID`
   repository variable in CI).
2. **Backend initialization**: Invokes `scripts/Initialize-Backend.ps1` with
   Microsoft Entra Blob authentication (`use_azuread_auth=true`) and either
   `use_cli=true` or `use_oidc=true`.
3. **Infrastructure validation and convergence**: Runs `terraform validate`,
   creates a saved execution plan (`environment.tfplan`) with a 60-second lock
   timeout, applies that exact plan, and reads `terraform output -json`.
   Provider blocks in `infra/environment/providers.tf` set both
   `resource_provider_registrations = "none"` (`azurerm`) and
   `skip_provider_registration = true` (`azapi`) so the RG-scoped deployment
   identity never attempts subscription-scope provider registration.
4. **Deterministic asset packaging**: Calls `New-SreAgentAssetPackage`
   (`scripts/DataPlane.ps1`) to validate `sre-agent/manifest.json`, all
   discovered resource manifests and referenced Markdown files across
   `sre-agent/<kind>/<name>/`, and `sample/checkout.py`, staging them into a
   clean temporary package directory and computing the sample's SHA-256 hash.
5. **Data-plane reconciliation**: Resolves the SRE Agent name from the
   non-secret `agent_id` Terraform output and invokes
   `scripts/Deploy-Assets.ps1 -AgentName <name> -ResourceGroupName <rg> -PackagePath <staged-dir>`
   to reconcile all discovered resources (`skills/checkout-investigation`,
   `agents/checkout-investigator`, and
   `scheduledtasks/checkout-daily-investigation`) in topological order.
6. **Non-sensitive summary and cleanup**: Writes resource names, workspace
   customer ID, sample SHA-256, and `Configured`/`Unchanged` asset statuses to
   `-SummaryPath` (`GITHUB_STEP_SUMMARY` in Actions). A `finally` block removes
   any leftover `environment.tfplan` and temporary staged asset package
   directory even if Terraform or data-plane reconciliation throws.

## Bootstrap-to-CI handoff

`infra/environment` grants `SRE Agent Administrator` at agent scope to both the
deployment UAMI and the interactive operator (`var.operator_object_id`). Because
a federated service principal in GitHub Actions cannot call `az ad
signed-in-user show`, `infra/bootstrap/outputs.tf` exports
`AZURE_OPERATOR_OBJECT_ID` in `github_variables`, and
`scripts/Bootstrap.ps1 -Apply -ConfigureGitHub` publishes all nine non-secret
repository variables (`AZURE_CLIENT_ID`, `AZURE_OPERATOR_OBJECT_ID`,
`AZURE_RESOURCE_GROUP_NAME`, `AZURE_SUBSCRIPTION_ID`, `AZURE_TENANT_ID`,
`SRE_AGENT_LOCATION`, `TF_STATE_CONTAINER_NAME`, `TF_STATE_KEY`, and
`TF_STATE_STORAGE_ACCOUNT_NAME`).

If an existing bootstrap predates Phase 5, refresh the repository variables
before running `deploy.yml`:

```powershell
.\scripts\Bootstrap.ps1 -StateStorageAccountId <supplied-account-arm-id> -Apply -ConfigureGitHub
```

## Running end-to-end delivery locally

Operators can run the exact same orchestrator locally in `pwsh` or Windows
PowerShell 5.1:

```powershell
.\scripts\Deploy-Environment.ps1 `
    -StorageAccountName <supplied-account> `
    -ContainerName sre-checkout `
    -StateKey checkout.tfstate `
    -Authentication AzureCli
```

To toggle the controlled checkout fault during a local operator run, pass
`-FaultEnabled` (or `-FaultEnabled:$true`, and rerun omitting `-FaultEnabled`
or passing `-FaultEnabled:$false` to restore healthy traffic). The hosted
`deploy.yml` workflow always converges `fault_enabled=false` so merges to `main`
leave the lab workload healthy.

## Verification evidence

Static and mocked evidence:

- `actionlint`, `gitleaks`, `git diff --check`, and `terraform fmt`/`validate`
  pass across `infra/bootstrap`, `infra/environment`, and `.github/workflows/deploy.yml`.
- Cloud-free Pester tests in `tests/DataPlane.Tests.ps1` and
  `tests/Deploy-Environment.Tests.ps1` (49 total tests across the repository,
  passing in both `pwsh` and Windows PowerShell 5.1) verify deterministic asset
  package staging, missing-file rejection, `-PackagePath` loading, ordered
  Terraform-to-data-plane orchestration, PR/non-`main` rejection in CI, plan and
  package directory cleanup on Terraform or data-plane failures, and summary
  generation.

Live local and hosted evidence recorded **November 16, 2026**:

- `.\scripts\Bootstrap.ps1 -StateStorageAccountId ... -Apply -ConfigureGitHub`
  published `AZURE_OPERATOR_OBJECT_ID` to GitHub repository variables with zero
  Azure resource changes.
- `.\scripts\Deploy-Environment.ps1 -StorageAccountName satfstatecmhcus -ContainerName sre-checkout -StateKey checkout.tfstate -Authentication AzureCli`
  executed end-to-end in both `pwsh` and Windows PowerShell 5.1 against the
  West US 3 environment (`rg-sre-checkout-westus3`, agent
  `sre-checkout-da3a0ee8`), completing `terraform apply` with `0 added, 0
  changed, 0 destroyed`, staging the checkout asset package (sample SHA-256
  `a4b166146fc5ffc8770c427418a3112e29ab22c058c53f42a44dc754344bf188`), and
  reporting `Unchanged` for `skills/checkout-investigation`,
  `agents/checkout-investigator`, and
  `scheduledtasks/checkout-daily-investigation`.
- After the owner merged #6 (`ef75176`) to `main`, **Deploy checkout
  environment** (`deploy.yml`, run `43942955764`) authenticated with GitHub OIDC
  (`repo:christopherhouse@748998/Azure-SRE-Agent-Deployment-Automation@1457055905:ref:refs/heads/main`),
  converged Terraform (`0 added, 0 changed, 0 destroyed`), and verified all
  three SRE Agent data-plane assets (`Unchanged`) in 43 seconds while
  serializing cleanly with `Verify keyless bootstrap` (`43942955681`).
- See [demonstration.md](demonstration.md) for the Phase 6 live fault,
  investigation, and recovery walkthrough.
