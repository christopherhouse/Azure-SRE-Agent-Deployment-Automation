---
name: deployment-contract-review
description: Review a proposed infrastructure, PowerShell, or workflow change for SRE Agent ownership and identity gaps before implementation or PR handoff. Use for deployment contract reviews, bootstrap readiness, and ARM versus data-plane ownership analysis.
---

# Deployment contract review

Read `.github/copilot-instructions.md` for shared constraints and the relevant
phase's completion criteria in `docs/implementation-plan.md`. This skill is a
read-only evidence review, not permission to provision resources or merge.

1. Establish the reviewed scope from the request and changed files. For a PR,
   inspect its base/head diff, not unrelated worktree changes. If no deployment
   code exists, report that explicitly rather than infer an implementation.
2. Trace each affected object from definition through caller to API request.
   Record a compact table: object, owning tool, control/data plane, identity,
   permission scope, repeat-run behavior, and file/line evidence.
3. Check identity boundaries separately: operator bootstrap, CI deployment,
   Terraform Blob state access, agent monitoring, and GitHub source/trigger
   connections. Mark unused boundaries not applicable. Distinguish the state
   account's subscription from the selected target subscription using evidence.
4. For each changed API or integration, verify audience, authentication,
   ownership/update semantics, and supported region/version against current
   primary documentation. Do not send repository content or credentials to a
   public research service. Treat an absent documented contract as unresolved.
5. Trace the second run and a deliberate failure: identify how existing owned
   objects converge, unmanaged objects are handled, errors reach the job, and
   cleanup preserves externally owned state resources. Do not execute writes
   or live failure injection as part of this review.
6. Report only evidence-backed gaps, with affected file/line and a concrete
   resolution or missing fact. Separate static evidence, mocked tests, and live
   evidence; list unverified runtime claims as unverified. If there are no gaps,
   say so only for the reviewed scope.
