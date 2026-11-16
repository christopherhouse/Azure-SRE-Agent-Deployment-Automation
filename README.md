# Azure SRE Agent deployment automation

A keyless, Git-driven Azure SRE Agent example built around **Checkout Reliability
Lab**: a small, deliberately faultable checkout workload, structured telemetry,
and an evidence-based agent investigation.

**Status:** All six phases are implemented and verified. Phase 2 keyless
bootstrap and Phase 5 end-to-end delivery (`deploy.yml`) are verified both
locally and by trusted hosted GitHub OIDC workflows on `main` (runs
`43915056852` and `43942955764`). Phase 3 infrastructure and the synthetic
checkout workload, Phase 4 data-plane assets, and the Phase 6 controlled fault,
Log Analytics telemetry, live SRE Agent investigation, scheduled-task drift
reconciliation, and recovery walkthrough are deployed and verified; see
[Demonstration and operator handoff](docs/demonstration.md) for reproduction,
evidence, and explicit OAuth/webhook boundaries.

## Start here

- [Project charter](docs/project-charter.md): outcomes, boundaries, and decisions.
- [Implementation plan](docs/implementation-plan.md): ordered phases and their
  completion criteria.
- [Contributing](CONTRIBUTING.md): local setup, checks, and the branch/PR workflow.
- [Identity and state bootstrap](docs/bootstrap.md): ownership, commands,
  permissions, recovery, live evidence and remaining verification.
- [Environment and checkout lab](docs/environment.md): infrastructure ownership,
  local deployment, constrained CI RBAC, telemetry and controlled fault.
- [Data-plane assets](docs/data-plane.md): versioned investigation, PowerShell
  reconciliation, ownership, local evidence and integration limitations.
- [GitHub Actions delivery](docs/delivery.md): ordered environment + data-plane
  orchestrator, deterministic asset packaging, and trusted `main`-only CI/CD.
- [Demonstration and operator handoff](docs/demonstration.md): end-to-end
  reproduction, controlled fault and live investigation walkthrough,
  troubleshooting, costs, and safe cleanup.

## Deployment contract

One environment will deploy to **West US 3**, in a new resource group in the
operator's selected Azure CLI subscription. Terraform will use direct Azure
provider resources, **not Azure Verified Modules (AVM)**. PowerShell will deploy
supported SRE Agent data-plane assets.

The existing Azure Storage state account is externally owned. Its subscription
must not be assumed to be the deployment subscription. Use Microsoft Entra Blob
authentication locally and GitHub OIDC in CI; never use account keys, SAS tokens,
API keys, PATs, or long-lived client secrets. Do not log short-lived tokens or
generated webhook URLs.

Pull requests run without Azure access. Later, an owner-merged change to `main`
will deploy through a dedicated federated identity, without a manual deployment
approval gate. Unsupported keyless integrations must be documented, not bypassed.

## Repository map

| Path | Purpose |
| --- | --- |
| `docs/` | Charter, phased plan, and future operator documentation |
| `infra/bootstrap/` | Operator-run local-state Terraform: RG, CI identity, federation and scoped state access |
| `infra/environment/` | Entra Blob backend, agent, monitoring, private worker and scoped RBAC |
| `sample/` | Dependency-free synthetic checkout worker and unit tests |
| `assets/checkout/` | Investigation skill, custom agent, paused task and supporting prompts |
| `scripts/` | PowerShell bootstrap orchestration, backend/probe helpers and local checks |
| `tests/` | Cloud-free mocked Pester tests |
| `.github/copilot-instructions.md` | Shared project guidance for Copilot |
| `.github/skills/deployment-contract-review/` | On-demand deployment ownership and authentication review |
| `.github/workflows/checks.yml` | Non-deploying workflow validation and secret detection |
| `.github/workflows/verify-bootstrap.yml` | Trusted main-only OIDC, ARM and Blob/backend verification |
| `.github/workflows/deploy.yml` | Trusted main-only environment and SRE Agent data-plane deployment |

## Initial checks

Every PR to `main` and push to `main` runs **Workflow validation** (actionlint)
and **Secret scan** (Gitleaks), plus **Terraform validation** and PowerShell
analysis/mocked tests on hosted `pwsh` and Windows PowerShell 5.1, and
**Sample validation** for the Python worker. No Azure
identity or repository secrets are provided to PR checks. The separate trusted
bootstrap verification and environment deployment workflows never run on PRs.

The repository also enables GitHub secret scanning and push protection. These
are complementary safeguards, not proof that arbitrary content is safe to commit.

## License

See [LICENSE](LICENSE).
