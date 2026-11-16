# Project boundaries

Read `docs/project-charter.md` and `docs/implementation-plan.md` before work.
Follow the current phase; do not invent unsupported SRE Agent APIs or expand
into production remediation, multiple environments, or unrelated scenarios.
Use `README.md` for navigation and `CONTRIBUTING.md` for setup and exact checks.

Terraform owns infrastructure. PowerShell owns intended SRE Agent data-plane
assets. Establish one owner per object; no Terraform/PowerShell double ownership.
Use direct Azure provider resources and AzAPI where needed, **not AVM** in this
repository. Pin providers and commit their lock file when introduced.
Confirm current schemas, API support, and regional availability with official
documentation before implementing preview-dependent behavior.

Deploy one new resource group in West US 3 in the selected Azure CLI
subscription. The supplied remote-state account is externally owned and may be
in a different subscription; never change shared account settings or delete it.

# Identity and trust

Use Entra identities: local Azure CLI, GitHub OIDC in deployment jobs, and the
agent's user-assigned managed identity for monitoring access. No API keys,
storage account keys, SAS tokens, PATs, app private keys, or long-lived client
secrets. Never log tokens, state, or generated webhook URLs.
Use least privilege and container-scoped Blob data access for state.
The eventual backend must use Entra Blob auth and CI OIDC, never key fallback.

Keep PR checks cloud-free and unprivileged, including forked PRs. No Azure
credentials, OIDC permissions, remote state, or deployment in PR jobs.
Pin Actions by full commit SHA, minimize permissions, and serialize eventual
deployments. Main-branch deployment has no manual approval gate.
Report unsupported keyless integrations instead of substituting credentials or
unprotected public webhooks.

# Implementation and validation

Use Windows PowerShell 5.1-compatible syntax/APIs and support hosted `pwsh`.
Use explicit native-command exit checks; terminating errors must fail the run.
Make create/update operations repeatable with explicit ownership, bounded
transient retries, and clear failures, never success-shaped fallbacks.
Write focused mocked Pester tests for new PowerShell behavior; document live
verification separately. Do not claim tests exist or ran when they do not.

Add directories only with real content. Keep Terraform state/plans, local
settings, credentials, packages, and test output out of Git. Run the existing
checks in `CONTRIBUTING.md`; introduce Terraform and PowerShell checks alongside
their implementation, with stable job names before requiring them.

# Delivery

Use `chore/`, `bugfix/`, or `feature/` branches and reviewable PRs against `main`.
The owner merges using merge commits. Never merge PRs, enable auto-merge, or
bypass branch protection. Preserve existing required check names.
Include scope, evidence, and limitations in the PR; do not claim a later phase
or a live deployment is complete based only on static validation.
