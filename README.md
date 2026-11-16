# Azure SRE Agent deployment automation

A keyless, Git-driven Azure SRE Agent example built around **Checkout Reliability
Lab**: a small, deliberately faultable checkout workload, structured telemetry,
and an evidence-based agent investigation.

**Status:** Phase 2 identity/state bootstrap implemented and locally exercised.
The main-only hosted OIDC verification awaits owner merge. The SRE Agent,
sample workload and end-to-end deployment remain later-phase work.

## Start here

- [Project charter](docs/project-charter.md): outcomes, boundaries, and decisions.
- [Implementation plan](docs/implementation-plan.md): ordered phases and their
  completion criteria.
- [Contributing](CONTRIBUTING.md): local setup, checks, and the branch/PR workflow.
- [Identity and state bootstrap](docs/bootstrap.md): ownership, commands,
  permissions, recovery, live evidence and remaining verification.

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
| `infra/environment/` | Entra Blob backend; workload infrastructure arrives in Phase 3 |
| `scripts/` | PowerShell bootstrap orchestration, backend/probe helpers and local checks |
| `tests/` | Cloud-free mocked Pester tests |
| `.github/copilot-instructions.md` | Shared project guidance for Copilot |
| `.github/skills/deployment-contract-review/` | On-demand deployment ownership and authentication review |
| `.github/workflows/checks.yml` | Non-deploying workflow validation and secret detection |
| `.github/workflows/verify-bootstrap.yml` | Trusted main-only OIDC, ARM and Blob/backend verification |

Create `assets/` and `sample/` when their first implementation files are added;
empty placeholder directories are intentionally omitted.

## Initial checks

Every PR to `main` and push to `main` runs **Workflow validation** (actionlint)
and **Secret scan** (Gitleaks), plus **Terraform validation** and PowerShell
analysis/mocked tests on hosted `pwsh` and Windows PowerShell 5.1. No Azure
identity or repository secrets are provided to PR checks. The separate trusted
bootstrap verification workflow never runs on PRs.

The repository also enables GitHub secret scanning and push protection. These
are complementary safeguards, not proof that arbitrary content is safe to commit.

## License

See [LICENSE](LICENSE).
