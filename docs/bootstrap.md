# Phase 2: identity and state bootstrap

The initial bootstrap creates seven Terraform-owned objects: one resource group in
West US 3, a GitHub deployment UAMI, its main-branch federated credential, one
private state container, and three role assignments. It does not create an SRE
Agent, workload, or agent data-plane assets.

## Ownership and permissions

| Object / boundary | Owner and plane | Identity and scope | Repeat-run behavior |
| --- | --- | --- | --- |
| Existing state account, Blob service, existing containers and networking | External; never a managed Terraform resource | Operator reads ARM settings | Never changed or deleted |
| `rg-sre-checkout-westus3` | `infra/bootstrap`, ARM | Interactive operator; subscription RG creation | Refresh/update same group; destruction blocked |
| `id-sre-checkout-github` and `github-main` | `infra/bootstrap`, ARM | Operator; target RG identity permissions | Same identity and exact main subject; identity destruction blocked |
| `sre-checkout` container | `infra/bootstrap`, ARM through AzAPI | Operator; container write on supplied account | Same private container; destruction blocked |
| Deployment Contributor assignment | `infra/bootstrap`, ARM | Operator role-assignment write; target RG only | Deterministic assignment name |
| Deployment and operator Blob assignments | `infra/bootstrap`, ARM | Operator role-assignment write; dedicated container only | Deterministic assignment names |
| `checkout.tfstate` | `infra/environment`, Entra Blob backend | Local CLI user or GitHub OIDC UAMI; container only | Backend locking, no key/SAS fallback |
| GitHub repository variables | `Bootstrap.ps1`, GitHub API | Existing authenticated `gh` operator; repository administration | Set same nine non-secret variables from Terraform outputs |
| Agent monitoring, GitHub source connection and investigation triggers | Not applicable yet | Separate identities/permissions in later phases | Not implemented or claimed |

The bootstrap identity and the eventual monitoring UAMI are different objects.
Initially CI receives **Contributor only on the target RG**, not subscription
Owner, User Access Administrator, state-account Contributor or role-assignment
write. Phase 3 adds an optional operator-established, conditioned RBAC
delegation for exact environment roles/principals, described in
[environment.md](environment.md). Contributor itself cannot assign roles.

Bootstrap-owned objects must not also be declared in `infra/environment`.
Phase 3 looks up the existing RG instead of creating or importing it again.
The deployment identity can manage resources in its RG, including identities;
branch protection and trusted main-only workflow execution remain essential.
Never add bootstrap apply or PR OIDC trust to work around that boundary.

## Prerequisites

Use AzureCloud, GitHub.com, Terraform **1.15.2**, Azure CLI, GitHub CLI, and
Windows PowerShell 5.1 or `pwsh`. Providers are pinned to AzureRM **5.14.0**
and AzAPI **2.13.0**, with Windows/Linux checksums committed. No Graph app
registration, private key, client secret, or extra credential is created.

Sign in interactively with `az login` and `gh auth login`. Select the intended
target subscription with `az account set --subscription <target-subscription>`.
The script captures that selection; it never switches the active subscription.
Supply the state account's full ARM ID separately, even if both subscriptions
happen to match. Cross-subscription, same-tenant accounts are supported;
cross-tenant accounts, sovereign clouds, custom Blob endpoints, and customized
GitHub subject templates are explicitly unsupported by this bootstrap.

The operator needs RG creation in the target subscription, identity/federation
management in that RG, container creation on the supplied account, and
`Microsoft.Authorization/roleAssignments/write` at the RG and container scopes.
Owner, or appropriately scoped Contributor plus User Access Administrator,
can establish this. Subscription Owner alone is not Blob data access: bootstrap
explicitly assigns the signed-in user Storage Blob Data Contributor on the
dedicated container. The script uses `az ad signed-in-user show`; a service
principal is not accepted for interactive bootstrap.

Before provisioning, inspect effective operator permissions and provider state:

```powershell
az account show --query '{subscription:id,tenant:tenantId}' -o json
if ($LASTEXITCODE -ne 0) { throw 'Account lookup failed.' }
$targetSubscription = az account show --query id -o tsv
if ($LASTEXITCODE -ne 0) { throw 'Subscription lookup failed.' }
az rest --method get --url "https://management.azure.com/subscriptions/$targetSubscription/providers/Microsoft.Authorization/permissions?api-version=2022-04-01" -o json
if ($LASTEXITCODE -ne 0) { throw 'Permission lookup failed.' }
```

The wrapper checks registration of `Microsoft.App`, `Microsoft.ManagedIdentity`,
and `Microsoft.Authorization`, and advertised West US 3 support for
`Microsoft.App/agents`. The state subscription must already have
`Microsoft.Storage` registered. It does not register providers or change policy.
Advertised availability is not a successful SRE Agent deployment or a guarantee
of subscription quota; those checks belong to Phase 3.

## Plan, apply, and repeat

Use the supplied account ID, not an account discovered by name:

```powershell
$stateAccountId = '/subscriptions/<state-subscription>/resourceGroups/<state-rg>/providers/Microsoft.Storage/storageAccounts/<account>'
.\scripts\Bootstrap.ps1 -StateStorageAccountId $stateAccountId
.\scripts\Bootstrap.ps1 -StateStorageAccountId $stateAccountId -Apply -ConfigureGitHub
```

The default is plan-only. `-Apply` creates and applies a saved plan from the
same invocation, with native failures terminating the run. `-ConfigureGitHub`
requires `-Apply`; it sets the nine non-secret values in
`infra/bootstrap/outputs.tf` (including `AZURE_OPERATOR_OBJECT_ID` for Phase 5
CI role-assignment preservation). A failed variable update fails the run; rerun
the same command to finish partial configuration.

The wrapper rejects credential/key environment variables and CLI argument
injection overrides, inspects the external account without listing keys, and
fails if network access does not permit ordinary hosted runners. It never
enables public access, adds firewall exceptions, or changes shared tags.
The main federated credential uses the subject prefix actually returned by
GitHub, including immutable owner/repository IDs where enabled, plus
`:ref:refs/heads/main`. Custom subject claims need explicit design work instead
of a guessed credential.

Local settings are written to ignored
`infra/bootstrap/bootstrap.auto.tfvars.json`. Local bootstrap state and its
backup remain in ignored `infra/bootstrap/terraform.tfstate*`; preserve them
in restricted operator-controlled storage. Never log, commit, or upload state
or plan files to PRs or Actions artifacts. Bootstrap is intentionally
independent of the remote backend it establishes and is never run by CI.

Rerun the same bootstrap command to converge partial applies. There are no
imperative Azure create operations in PowerShell; provider retries/timeouts
handle transient provisioning responses. Authentication, authorization and
network failures are not suppressed or retried indefinitely. New RBAC grants
can take time to propagate: if a subsequent probe receives 403, wait for
propagation and rerun it; do not broaden permissions or enable keys.

```powershell
terraform -chdir=infra\bootstrap plan -input=false -detailed-exitcode
if ($LASTEXITCODE -ne 0) { throw 'Expected a zero-drift bootstrap plan.' }
.\scripts\Test-StateAccess.ps1 -StorageAccountName <account> -ContainerName sre-checkout
.\scripts\Initialize-Backend.ps1 -StorageAccountName <account> -ContainerName sre-checkout -StateKey checkout.tfstate -Authentication AzureCli
```

The probe writes a uniquely named `bootstrap-probes/<guid>.txt`, acquires a
60-second lease, reads, releases, and deletes that blob in a `finally` block.
It never reads, overwrites, deletes, or leases `checkout.tfstate`. If a process
is killed or network access disappears during cleanup, inspect and remove
only that run's named probe after its finite lease expires.

## Trusted hosted verification

After the owner merges bootstrap changes, `Verify keyless bootstrap` runs on a relevant
push to `main`, or can be dispatched **on main**. It has no environment approval
gate. Only its Azure job receives `id-token: write`; PR checks remain cloud-free,
credential-free and backend-free, including forked PRs. Deployment concurrency
is serialized with the group `sre-checkout-deployment`; Phase 5 must reuse it.

The workflow signs in through Azure Login OIDC, checks target ARM access, runs
the non-state Blob probe, then initializes the environment backend with
`use_oidc=true`, `use_azuread_auth=true`, and `use_cli=false`. No Terraform
plan/apply, asset packaging or agent deployment occurs in this Phase 2 workflow.
Backend initialization can create the initial empty state blob; it does not
apply environment resources or overwrite existing state. The workflow uploads
no artifacts and does not print tokens,
lease IDs, state, or generated webhook URLs.

Local network inspection does not prove hosted-runner reachability. If the
hosted job fails, inspect the exact login/ARM/Blob/backend failure, permissions,
federation subject and account network policy without changing shared security.
The agent endpoint does not exist until Phase 3; hosted endpoint authentication
and reachability must be verified then.

## Recovery and cleanup

Keep the local bootstrap state and settings together. Do not initialize a
second bootstrap in another checkout and apply against the same objects.
An existing unmanaged object is an import/recovery decision, not permission
to overwrite it. If state is lost, inventory exact IDs and verify ownership
before importing the initial seven objects, plus the optional Phase 3
delegation if established, into the one bootstrap stack:

| Terraform address | Import ID |
| --- | --- |
| `azurerm_resource_group.target` | Target RG ARM ID |
| `azurerm_user_assigned_identity.deployment` | Deployment UAMI ARM ID |
| `azurerm_federated_identity_credential.main` | UAMI ID + `/federatedIdentityCredentials/github-main` |
| `azapi_resource.state_container` | State account ID + `/blobServices/default/containers/sre-checkout` |
| `azurerm_role_assignment.deployment_resources` | Full existing RG role-assignment ARM ID |
| `azurerm_role_assignment.deployment_state` | Full existing container role-assignment ARM ID |
| `azurerm_role_assignment.operator_state` | Full existing container role-assignment ARM ID |
| `azurerm_role_assignment.environment_rbac[0]` (optional Phase 3 extension) | Full existing RG delegation role-assignment ARM ID |

Use `terraform -chdir=infra\bootstrap import <address> <full-id>`, checking each
exit code, then review a normal plan before applying. Role-assignment IDs can
be discovered with `az role assignment list --scope <exact-scope> --all`;
the code derives stable UUIDv5 names from scope, principal and role purpose.
Import existing assignments rather than creating duplicate grants. Do not
recreate identities merely to resolve a lost state file.

For intentional retirement, stop deployment, remove the GitHub variables,
and retire future environment resources before the bootstrap. RG, identity
and container destruction is blocked by `prevent_destroy`; changing that
requires an explicit reviewed retirement change. Preserve state/history as
needed before deleting this project's container or scoped grants. Never delete
the shared account, its resource group, Blob service, existing `tfstate`
container, or unrelated blobs/roles. There is deliberately no broad cleanup
script.

## Evidence recorded November 16, 2026

Local live evidence: selected target and supplied account currently share
subscription `04769e32-22a3-4978-b533-1d6ee0c9620a`; their relationship was
checked, not assumed. The account is `satfstatecmhcus`, in Central US, with
Shared Key disabled, public networking enabled and default network action
Allow. These settings were inspected and left unchanged. West US 3 was
advertised for `Microsoft.App/agents`. All seven bootstrap objects applied,
the next plan returned zero changes, Entra Blob probe operations succeeded,
and local Entra backend initialization succeeded. A full second bootstrap
apply through Windows PowerShell 5.1 changed zero objects; the probe left no
probe blobs behind. Backend initialization materialized `checkout.tfstate`.

Mocked evidence: Pester exercises plan-only behavior, separate subscription
selection, repeated orchestration, blocked networking, cross-tenant rejection,
native apply failures, GitHub subject handling, CLI/OIDC backend flags, PR
rejection, forbidden credentials and probe cleanup. This does not prove
federation or hosted networking. Hosted OIDC/ARM/Blob/backend verification is
verified by run `43915056852` on merged `main` commit `fda1b8f` on November 16,
2026: its `Keyless backend access` job succeeded. Agent-endpoint verification
remains separate Phase 3 evidence.

Phase 3 extends bootstrap with the optional
`azurerm_role_assignment.environment_rbac[0]`. It is created only after the
operator supplies the monitoring UAMI principal. This brings bootstrap to eight
managed objects, without changing ownership of the original seven or the
external account. Its import ID is the full existing RG role-assignment ARM ID.
The exact conditioned write/delete boundary and repeat commands are in the
environment guide.

## Primary contracts

- [Terraform Azure Blob backend](https://developer.hashicorp.com/terraform/language/backend/azurerm):
  Entra data plane, container-scoped Storage Blob Data Contributor, OIDC/CLI.
- [Managed identity federation](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation-create-trust-user-assigned-managed-identity):
  exact issuer/subject and `api://AzureADTokenExchange` audience.
- [GitHub OIDC subject reference](https://docs.github.com/en/actions/reference/security/oidc)
  and [immutable subject migration](https://learn.microsoft.com/en-us/entra/workload-id/workload-identities-github-immutable-subjects).
- [Container ARM schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.storage/2025-08-01/storageaccounts/blobservices/containers):
  scoped container properties and private access, without account mutation.
- [AzureRM container caveat](https://registry.terraform.io/providers/hashicorp/azurerm/5.14.0/docs/resources/storage_container):
  access-level updates use Shared Key; this repository uses AzAPI instead.
- [Storage Blob Data Contributor](https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/storage#storage-blob-data-contributor)
  and [supported SRE Agent regions](https://learn.microsoft.com/en-us/azure/sre-agent/supported-regions).
