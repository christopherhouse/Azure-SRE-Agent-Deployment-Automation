# Azure SRE Agent deployment automation

A keyless, Git-driven Azure SRE Agent example built around **Checkout Reliability
Lab**: a small, deliberately faultable checkout workload, structured telemetry,
and an evidence-based agent investigation.

**Status:** repository bootstrap only. Infrastructure, the sample workload, and
deployment commands arrive in later phases; nothing here currently deploys Azure
resources.

## Start here

- [Project charter](docs/project-charter.md): outcomes, boundaries, and decisions.
- [Implementation plan](docs/implementation-plan.md): ordered phases and their
  completion criteria.
- [Contributing](CONTRIBUTING.md): local setup, checks, and the branch/PR workflow.

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
| `.github/copilot-instructions.md` | Shared project guidance for Copilot |
| `.github/skills/deployment-contract-review/` | On-demand deployment ownership and authentication review |
| `.github/workflows/checks.yml` | Non-deploying workflow validation and secret detection |

Create `infra/`, `assets/`, `scripts/`, `tests/`, and `sample/` when their first
implementation files are added; see the plan for their responsibilities. Empty
placeholder directories are intentionally omitted.

## Initial checks

Every PR to `main` and push to `main` runs **Workflow validation** (actionlint)
and **Secret scan** (Gitleaks). No Azure identity or repository secrets are
provided. Terraform formatting/validation and PowerShell lint/Pester checks will
be added alongside the code they validate, not as empty passing jobs.

The repository also enables GitHub secret scanning and push protection. These
are complementary safeguards, not proof that arbitrary content is safe to commit.

## License

See [LICENSE](LICENSE).
