# Implementation plan

## Working agreement

The owner merges pull requests; the implementation agent never merges them.
All changes go through `chore/`, `bugfix/`, or `feature/` branches. `main` is
protected, and the repository is configured for merge commits only. No
deployment approval gate is required. Each phase should be delivered in
reviewable increments rather than one oversized pull request.

The planning documents themselves are not the repository bootstrap. **Phase 1
is the first implementation work**, before application or infrastructure
implementation.

## Phase 1: Repository bootstrap

1. Establish a clear repository layout and contributor guidance, including
   `.gitignore` and `.gitattributes` for Terraform, PowerShell, generated files,
   local state, and platform-appropriate line endings.
2. Add focused GitHub Copilot instructions covering the project boundaries,
   identity-only authentication, Terraform without AVM, PowerShell, tests, and
   the branch/PR workflow.
3. Add only useful, task-specific Copilot custom agents or skills, with clear
   responsibilities and no duplicated project instructions. Verify their
   supported file locations and syntax against current GitHub documentation.
4. Add an initial README and contributor-oriented setup and workflow guidance.
   Account for Windows PowerShell 5.1 locally and PowerShell on hosted runners.
   Keep templates and placeholders minimal; do not commit credentials.
5. Propose and introduce useful PR checks as their tools and code are added:
   Terraform formatting and validation, PowerShell lint and tests, workflow
   validation, and secret scanning. Require only checks that actually run and
   have stable names; avoid blocking the repository on nonexistent checks.

**Done when:** a contributor can navigate the repository, understand the
project constraints, and submit a PR using the documented workflow. Foundational
instructions, repository settings, and initial checks agree with each other.

## Phase 2: Identity, state, and deployment bootstrap

Implementation and local live evidence are in [bootstrap.md](bootstrap.md).
The trusted hosted OIDC completion check succeeded on November 16, 2026 after
the owner's merge of #3 (run `43915056852`). The bootstrap Terraform
stack owns the target RG, deployment identity/federation, dedicated container
and bootstrap role assignments; the environment stack must not duplicate them.

1. Inspect the active `az` subscription and confirm its tenant, target region,
   resource provider availability, and permissions. Do not equate it with the
   subscription that contains the supplied state account.
2. Inspect the existing state account's network access, container options, and
   RBAC without retrieving account keys or changing shared account settings.
   Select or create a suitable container and state blob name. Grant the
   deployment identity the minimum Blob data access required at container scope.
3. Bootstrap a dedicated GitHub Actions identity with an appropriately scoped
   GitHub OIDC federated credential. Configure non-secret GitHub variables for
   identity, subscription, and backend settings. Use GitHub-hosted runners and
   grant `id-token: write` only to jobs that need Azure access.
4. Resolve the bootstrap dependency explicitly: the bootstrap process must
   provision or establish ownership of its own identity, role assignments,
   state access, and any target resource group without relying on the Terraform
   state it is creating. Document idempotence, permissions, ownership, import
   where applicable, and recovery. Avoid unmanaged duplicate resources.
5. Configure the Terraform Azure Storage backend for both OIDC and Entra Blob
   authentication in CI (`use_oidc` and `use_azuread_auth`), and Azure CLI/Entra
   authentication for local use. Never fall back to account keys or SAS.
6. Verify runner reachability to state, ARM, and the agent data-plane endpoint.
   If network policy blocks hosted runners, report the blocker rather than
   silently weakening the shared storage account's security.

**Done when:** the operator can repeat the bootstrap safely, and a trusted
workflow can authenticate and access its state container without a key or
client secret. The state account itself remains externally owned.

## Phase 3: Terraform infrastructure and sample workload

Implementation, ownership, local operations and verification evidence are in
[environment.md](environment.md). Do not equate static validation with a
running agent, ingested telemetry or effective managed-identity query access.
On November 16, 2026, the operator applied the environment, verified a running
agent and worker, agent-executed workspace queries, fault/recovery ingestion
and zero-drift repeat plans. Hosted environment deployment remains Phase 5.

1. Define direct Azure provider resources, using AzAPI where required for
   supported SRE Agent ARM resources. Pin and lock provider dependencies.
   Use the bootstrap-owned resource group in West US 3 (look it up, do not
   redeclare it), and create an SRE Agent, its required monitoring identity
   resources, a workspace, and the minimum supporting resources.
2. Implement the Checkout Reliability Lab: a small, observable workload with
   synthetic traffic or a controlled fault that produces useful structured
   telemetry. Prefer the simplest supported hosting and logging approach that
   meets the keyless constraint; avoid introducing unnecessary services.
3. Grant the agent UAMI the least privileges needed for workspace queries,
   monitoring, and resource discovery. Separately scope the CI identity for
   deployment, role assignments, state, and agent configuration.
4. Export only the non-secret identifiers and endpoint information that later
   steps require. Do not place credentials or access tokens in Terraform
   configuration, outputs, state, logs, or artifacts.
5. Validate with formatting, initialization, validation, a real plan, apply, and
   a second plan that shows no unexpected drift. Check regional availability
   and current API schemas instead of assuming preview behavior.

**Done when:** one deployment produces a running agent and observable sample
workload, with working least-privilege monitoring access and stable state.

## Phase 4: Data-plane assets and PowerShell deployment

1. Design the investigation skill, custom agent, automation, and supporting
   prompts as version-controlled text. The investigation should correlate a
   checkout failure with workspace evidence and relevant source context.
2. Determine the authoritative API surface for each asset. Use Terraform for
   infrastructure and PowerShell for the intended data-plane deployment;
   explicitly document ownership where an asset could be managed by either
   plane, so two tools never fight over the same object.
3. Discover the agent endpoint from ARM and acquire short-lived Entra tokens
   for the documented data-plane audience. Do not log tokens or webhook URLs.
4. Implement repeatable create/update deployment, meaningful error messages,
   bounded retries for transient errors, and explicit handling of unsupported
   APIs and unmanaged existing objects. Support Windows PowerShell 5.1 and the
   CI runner's PowerShell where feasible, documenting any unavoidable
   differences. A failed operation must fail the run.
5. Add focused Pester tests for rendering, API request construction, failure
   handling, and repeat deployment using mocks; verify real agent configuration
   separately against the deployed environment.
6. Investigate GitHub repository connection and webhook/automation setup with
   current Microsoft guidance. Use a supported keyless path, including
   interactive OAuth if needed and compatible; document any unavoidable manual
   step or unsupported automation. Never substitute a PAT, private key, or
   public unprotected webhook merely to claim completion.

**Done when:** rerunning deployment converges the owned assets, a deliberate
failure is surfaced, and supported integrations can be verified without keys.
Document any integration that cannot meet the stated constraint.

## Phase 5: GitHub Actions delivery

1. On pull requests, run non-deploying checks for the changed Terraform,
   PowerShell, and workflow files. Do not expose Azure OIDC credentials or
   state to untrusted PR code, including forked PRs.
2. On merge to `main`, use the dedicated federated identity to initialize the
   backend, create a Terraform plan, apply that plan, package the relevant
   version-controlled assets, and deploy the data-plane configuration in order.
   Do not add a manual approval gate.
3. Limit workflow permissions and scope, pin actions to immutable revisions,
   avoid leaking tokens or sensitive state, and serialize deployments to the
   single environment. Define failure behavior so downstream steps do not run
   after a failed deployment.
4. Publish only safe validation and deployment summaries. Add a cloud-backed
   PR plan only if its trust model and limited permissions are explicitly
   addressed; static PR validation must remain useful without Azure access.

**Done when:** a PR runs its checks, and an owner-merged change deploys the
single environment end to end using federation, with no stored access keys.

## Phase 6: Demonstration and handoff

1. Exercise the controlled checkout fault and confirm relevant records appear in
   Log Analytics. Run the agent investigation and check that its answer uses
   the telemetry and, when supported, the connected repository.
2. Verify the supported automation or trigger path without exposing a generated
   webhook URL or bypassing the identity requirement. Record any manual or
   unsupported GitHub connection step.
3. Document prerequisites, bootstrap, local and CI deployment, example
   investigation, troubleshooting, costs, and cleanup. Cleanup must preserve the
   existing state account and avoid deleting unrelated resources.
4. Repeat the deployment to check idempotence; test failure reporting and
   demonstrate that no account keys or long-lived credentials are needed.

**Done when:** another operator can reproduce the scenario and understand what
is automated, what requires interaction, and what cannot meet the keyless
requirement with the currently supported APIs.

## Proposed layout

The bootstrap phase should refine this structure rather than create empty
directories merely to match it:

```text
docs/                 Charter, plan, and operator documentation
infra/                Terraform configuration and provider lock file
assets/               Versioned SRE Agent definitions and prompts
scripts/              Bootstrap and data-plane PowerShell
tests/                Focused PowerShell and deployment tests
sample/               Checkout Reliability Lab workload
.github/              Copilot guidance and Actions workflows
```

## References

- [Microsoft SRE Agent labs](https://github.com/microsoft/sre-agent/tree/main/labs)
  and [Zava Learning](https://github.com/microsoft/sre-agent/tree/main/labs/zava-learning).
- [SRE Agent infrastructure-as-code guidance](https://learn.microsoft.com/en-us/azure/sre-agent/deploy-iac)
  and [API reference](https://learn.microsoft.com/en-us/azure/sre-agent/api-reference).
- [SRE Agent source code connections](https://learn.microsoft.com/en-us/azure/sre-agent/connect-code-service).
- [Terraform Azure Storage backend](https://developer.hashicorp.com/terraform/language/backend/azurerm).
- [GitHub Actions authentication to Azure with OIDC](https://learn.microsoft.com/en-us/azure/developer/github/connect-from-azure-openid-connect).
