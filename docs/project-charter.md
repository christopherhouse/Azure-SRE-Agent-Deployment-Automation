# Project charter: Azure SRE Agent deployment automation

## Vision

Create a practical, repeatable example of deploying and operating an Azure SRE
Agent with infrastructure and agent configuration maintained in Git. A reader
should be able to follow the repository from an empty target resource group to
a working reliability investigation, without managing API keys or access keys.

## Outcomes

- Deploy one Azure SRE Agent environment and its dependencies with Terraform.
- Maintain skills, custom agents, automations, hooks, and other supported agent
  configuration as reviewable text assets, deployed with PowerShell.
- Use GitHub Actions to validate changes, package the relevant artifacts, and
  deploy infrastructure and data-plane configuration.
- Connect the agent to monitored Azure resources with a user-assigned managed
  identity (UAMI), including a Log Analytics workspace, and connect a GitHub
  repository using a supported keyless approach.
- Demonstrate a realistic reliability investigation using a small, deliberately
  faultable sample workload, its telemetry, and source context.

## Boundaries and decisions

| Area | Decision |
| --- | --- |
| Environments | One environment, deployed to West US 3 in a new resource group. |
| Subscription | Use the subscription selected in the operator's Azure CLI session; do not assume it is the state account's subscription. |
| Infrastructure | Terraform with Azure providers, not Azure Verified Modules. |
| State | Reuse the existing, separately supplied Azure Storage account; authenticate to the Blob data plane with Microsoft Entra ID. |
| Authentication | Favor Azure identity throughout. Do not use API keys, storage account access keys, SAS tokens, or long-lived client secrets. Short-lived identity tokens are expected and must not be logged. |
| CI/CD | GitHub-hosted runners and federated Azure identity; no manual deployment approval. |
| Git | Work on `chore/`, `bugfix/`, or `feature/` branches. Protect `main`; the owner merges PRs using merge commits, not squash or rebase. |
| Implementation | Repository bootstrapping is the first implementation phase. |

This is an example, not a production-ready operations platform. Multi-environment
promotion, production remediation, and a broad library of unrelated scenarios
are out of scope.

## Demonstration scenario

The initial scenario is **Checkout Reliability Lab**: a small checkout-style
workload emits structured operational logs, with a controlled way to introduce
an error condition. The agent uses workspace evidence, a troubleshooting skill,
a custom investigation agent, and repository context to explain the failure
and suggest a remedy. An automation or trigger demonstrates initiating the
investigation when a supported, keyless path is available.

The workload and fault mechanism are design targets, not assumptions about a
specific Azure API. Prefer read-only investigation and synthetic test data; do
not grant broad write access or perform production-like destructive actions.

## Success criteria

1. A clean deployment uses the selected subscription and existing remote state
   with Microsoft Entra authentication, without account keys.
2. The GitHub workflow authenticates with workload identity federation, validates
   changes, and deploys after a PR is merged without an approval gate.
3. PowerShell deployments create or update the intended data-plane assets,
   report failures, and are safe to run again.
4. The agent's identity can query only the intended monitoring scope, and the
   sample investigation cites relevant telemetry and source context.
5. Repository, webhook, and automation integrations are demonstrated only when
   their supported authentication meets the keyless requirement; any limitation
   is explicit rather than bypassed with a stored key.
6. Another operator can follow the documentation to bootstrap, deploy, verify,
   and clean up the demo without deleting or modifying the shared state account.

## Constraints to resolve during implementation

- Confirm state container and blob names, existing permissions, and whether
  GitHub-hosted runners can reach the storage account and agent endpoint.
- Verify that the selected subscription, West US 3, provider registration, and
  current Azure SRE Agent APIs support the proposed resources.
- Confirm which agent features are available through ARM versus the data plane;
  preview API contracts can change.
- GitHub source connections have their own authentication requirements.
  Evaluate supported OAuth and automation paths without introducing PATs, app
  private keys, or other credentials that violate the project's constraints.
- HTTP trigger endpoints may be public and server-generated. Do not publish a
  trigger URL or assume a webhook is authenticated; demonstrate only a
  supported invocation and exposure model compatible with these constraints.

See [implementation-plan.md](implementation-plan.md) for the ordered work,
verification criteria, and references.
