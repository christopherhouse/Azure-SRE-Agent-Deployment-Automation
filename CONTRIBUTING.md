# Contributing

Read the [charter](docs/project-charter.md) and
[implementation plan](docs/implementation-plan.md) before changing scope.
Keep each PR focused on a reviewable part of one phase.

## Local setup

For repository bootstrap work, install Git, GitHub CLI (`gh`), and the validators
below. Authenticate GitHub CLI with `gh auth login`; do not put credentials in
files or shell history. Azure access is not needed for the initial PR checks.

Use **Windows PowerShell 5.1** as the local compatibility baseline for future
deployment scripts. Hosted runners use PowerShell 7 (`pwsh`) when a PowerShell
job is added. Scripts must work in both unless a concrete incompatibility is
documented. Avoid PowerShell 7-only syntax/APIs, including `??`, ternary
expressions, `&&`, and `ConvertFrom-Json -Depth`; check `$LASTEXITCODE` after
native commands and throw on failure. Prefer ASCII in scripts so Windows
PowerShell 5.1 does not depend on BOM-less UTF-8 decoding.

Git normalizes text to LF in the index. `.gitattributes` checks PowerShell and
Windows command scripts out as CRLF; YAML, Terraform, and Markdown remain LF.
Do not change global Git settings to work around line endings.

Install **actionlint 1.7.12** and **Gitleaks 8.30.1** from their upstream releases
and put their executables on your PATH. Verify downloaded archives against the
published checksums. The CI workflow pins the Linux archive hashes; use the
matching Windows archives locally. Upstream documentation:

- [actionlint installation and usage](https://github.com/rhysd/actionlint)
- [Gitleaks installation and usage](https://github.com/gitleaks/gitleaks)

No Terraform providers, Azure resources, PowerShell modules, or deployment
identity are required yet. Later phases must add exact tool/provider/module
versions and setup commands together with their implementation.

## Local checks

Run these from the repository root in PowerShell; each command must exit zero:

```powershell
actionlint -shellcheck= -pyflakes=
if ($LASTEXITCODE -ne 0) { throw 'Workflow validation failed.' }

gitleaks dir --redact --no-banner .
if ($LASTEXITCODE -ne 0) { throw 'Working-tree secret scan failed.' }

gitleaks git --redact --no-banner .
if ($LASTEXITCODE -ne 0) { throw 'History secret scan failed.' }

git diff --check
if ($LASTEXITCODE -ne 0) { throw 'Whitespace check failed.' }
```

The working-tree scan covers new files before committing; the history scan
matches CI's full-history check. Keep scans redacted and never upload reports
containing credentials. CI disables actionlint's optional ShellCheck and
pyflakes integrations too, so Windows and hosted validation use the same rules.

Add Terraform formatting and backend-free validation when `infra/` exists.
Add PSScriptAnalyzer and focused mocked Pester tests with the first PowerShell
implementation, including Windows PowerShell 5.1 and hosted `pwsh` coverage.
These are planned checks, not current prerequisites or existing test suites.

## Branch and pull request workflow

Start from an up-to-date `main`, choosing `chore/`, `bugfix/`, or `feature/`:

```powershell
git switch main
git pull --ff-only
git switch -c chore/short-description
```

Make the smallest coherent change, run the applicable checks, and inspect
`git diff` and `git status --short`. Stage explicit paths rather than generated
output. Never commit state, plans, credentials, tokens, webhook URLs, or local
configuration; `.gitignore` is a convenience, not a security boundary.
Commit `.terraform.lock.hcl` once provider dependencies exist.

```powershell
git add <changed-paths>
git commit -m "chore: describe the change"
git push -u origin HEAD
gh pr create --base main --fill
```

Replace `<changed-paths>` with actual reviewed paths; do not paste it literally.
In the PR description, explain the change, validation performed, phase/scope,
and any remaining limitations. Include ownership, permission, and repeat-run
behavior when changing deployment code.

The **owner merges** PRs; implementation agents never merge, bypass protection,
or enable auto-merge. Use a **merge commit**, not squash or rebase. `main`
requires a PR and applies protection to administrators; force pushes and branch
deletion are disabled. No approving review is currently mandated.

Required checks are **Workflow validation** and **Secret scan**. PR branches
must be up to date with `main` before merging. Do not rename their job names or
add path filters without coordinating branch protection:
both checks must run on every PR, including documentation-only changes. Add
new required checks only after observing them run successfully on a PR.

## CI trust and settings

`checks.yml` uses GitHub-hosted Ubuntu runners, immutable action revisions,
checksum-verified validator releases, `contents: read`, and checkout without
persisted credentials. It runs on `pull_request`, pushes to `main`, and manual
dispatch. PR jobs must not request Azure OIDC, receive secrets, access Terraform
state, or deploy; do not switch to `pull_request_target` to execute PR content.
No reports or generated artifacts are uploaded.

GitHub secret scanning and push protection are enabled. Keep merge commits
enabled, squash/rebase disabled, and only real stable checks required. Repository
settings are managed in GitHub, not deployed by this bootstrap workflow.

## Copilot customization

Repository-wide guidance lives in `.github/copilot-instructions.md`. A single
task-specific skill lives at
`.github/skills/deployment-contract-review/SKILL.md`, with YAML `name` and
`description` frontmatter and procedural Markdown. It produces an ownership and
identity review from evidence; it does not deploy or repeat global instructions.
No speculative custom agents, setup workflow, or empty skills are included.

The format and location were checked against GitHub's
[repository instructions](https://docs.github.com/en/copilot/how-tos/copilot-on-github/customize-copilot/add-custom-instructions/add-repository-instructions)
and [agent skills](https://docs.github.com/en/copilot/how-tos/copilot-on-github/customize-copilot/customize-cloud-agent/add-skills)
documentation during bootstrap. Recheck that documentation when changing
customization formats.
