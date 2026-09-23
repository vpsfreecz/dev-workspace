---
name: mandatory-change-review
description: Run the required adaptive review of committed vpsFree.cz development changes after quick verification and before integration tests. Use for feature, bugfix, refactor, or cross-project work that changes code, schemas, APIs, protocols, configuration, documentation, tests, deployment behavior, or security posture; skip only dependency-only or generated update sessions without relevant code changes.
---

# Mandatory Change Review

## Purpose

Use this skill after all intended changes are committed and quick local
verification has passed, but before long integration tests are started. The
review is advisory, but Blocking and Important findings must be addressed as
described below before continuing.

The coordinating agent assigns one independent reviewer the adaptive set of
applicable review lanes. Prefer an eligible retained `reviewerN` in the current
session, selecting the lowest index. Use that member's saved model and reasoning
effort exactly; do not override either setting for review. If no member is
eligible (including a solo session), launch one fresh standalone reviewer using
the installed catalog's default development reviewer's model and effort. This
fallback does not add a member or change the roster. If no valid installed
catalog policy is available, stop and request direction rather than inventing
a model or accepting self-review. The reviewer performs the review directly
without nested reviewers or subagents.

An eligible retained reviewer is present, ready, independent of the work being
reviewed, and not occupied by an unrelated assignment. A member who authored
substantive changes is ineligible. Verify the selected member's session-bound
identity, role, state, and saved settings before assignment; omit model/effort
overrides when assigning it. A temporarily unavailable or unverified member is
not a reason to skip review: use the standalone fallback and record why.

Retain the same independent reviewer for findings, requested fixes, and later
relevant revisions of a coherent change. Replace it only when the change is
unrelated, independence was lost, the reviewer authored substantive fixes,
its identity or settings cannot be validated, or its policy became incompatible.

## Invocation Mode

First decide which role you are in:

- If you are coordinating the development session, follow the Main Agent
  Workflow.
- If you are a spawned reviewer, read Shared Reviewer Instructions and the
  reference for your assigned lane. Do not launch another reviewer.

## Reasoning Effort

Before assigning the reviewer, classify the overall change at the highest risk
present in any affected component. The classification informs the packet and
lane selection, not an override of the reviewer's configured effort:

- **Low:** a simple, localized, readily reversible change with no security,
  persisted-state, public-contract, destructive-operation, deployment, or
  compatibility consequence.
- **Medium:** a bounded implementation or cross-component change that remains
  reversible and compatible, with no high-risk characteristic below.
- **High:** authentication, authorization, tenant isolation, secrets, data
  loss, schemas or persisted state, incompatible public or cross-project
  contracts, protocols, host/node behavior, destructive or irreversible
  operations, deployment ordering, rollback, or mixed-version operation.

Use the selected reviewer's saved or catalog effort for every risk
classification and related review rerun. When uncertain, choose the higher
risk classification so the packet and selected lanes cover the concern.

## Review Lanes

The reviewer always covers the general lane. Add each specialist lane to the
same assignment when its trigger applies:

- **General:** always. Read
  [references/general-review.md](references/general-review.md).
- **Architecture and repetition:** hand-written implementation, test, build,
  workflow, or configuration logic changed; or the change affects an
  abstraction, extension point, reusable component, or cross-project
  interface. Read
  [references/architecture-review.md](references/architecture-review.md).
- **Scope and proportionality:** the change is medium or high risk, introduces
  or expands an abstraction, framework, compatibility layer, generalized
  safety mechanism, or cross-project capability, or grew materially during
  implementation or review. Read
  [references/scope-review.md](references/scope-review.md).
- **Risk and compatibility:** the change affects authentication,
  authorization, tenant isolation, security boundaries, persisted state,
  schemas, public or cross-project contracts, protocols, host/node behavior,
  destructive or irreversible operations, deployment, rollback, or
  mixed-version operation. Read
  [references/risk-review.md](references/risk-review.md).

Documentation-only changes normally use only the general lane. Combining lanes
does not permit omitting their references or collapsing their distinct concerns
into a superficial general review.

## Main Agent Workflow

1. Confirm the review is required. Skip only when the session contains no
   relevant code or design change, such as dependency-only updates, generated
   lockfile refreshes, or other mechanical metadata updates.
2. Make sure all intended changes are committed in every affected repository.
   Do not review a half-staged or partly uncommitted implementation.
3. Run quick verification first, using the local project guidance. Do not start
   long integration tests yet.
4. Classify the overall risk, then determine the
   applicable lanes using the triggers above. Read every applicable lane
   reference before preparing the review.
5. Prepare a review packet containing:
   - requested outcome and acceptance criteria;
   - initiative slug, plan/state files, affected repositories and worktrees;
   - base and head commits for every repository;
   - intended commit split and any deliberately bundled changes, with a
     concrete rationale for why they are inseparable;
   - explicit non-goals, rejected alternatives, and user decisions that bound
     the implementation or accepted residual behavior;
   - relevant dependency pins or configuration changes;
   - documentation changed or checked, with paths to project explanations,
     decision rationale and applicable operations or upgrade guidance; link
     individual rollout records separately, following the generic
     dev-session-documentation skill's placement rules; briefly explain when
     no documentation change was useful;
   - quick verification commands and results;
   - overall risk classification, its rationale, reviewer selection, model,
     and reasoning effort;
   - known compatibility and deployment assumptions;
   - for reusable or cross-project components, the owning component, public
     interface, and consumers discovered from imports, dependency pins,
     wrappers, manifests, documentation, and current repository state.
6. Check the current session roster and choose the lowest-index eligible
   `reviewerN`. Send the packet and all selected lanes to that member with
   `dev-session team assign <slug> --to reviewerN --message-stdin` (or the
   equivalent session-bound assignment), omitting `--model` and `--effort` so
   the saved settings govern the turn. Verify the resulting member identity,
   model, effort, and completed review report. If no member qualifies, use the
   installed catalog's default development team reviewer role as one fresh
   standalone agent with `fork_turns: "none"`, passing its exact model and
   effort explicitly. Verify its native identity and settings against that
   catalog. Native role TOMLs define behavior, not model, effort, or permission
   settings. Give either reviewer the review packet, this skill path, and
   instructions to read every selected lane reference and perform the review
   itself. Do not pass hidden conclusions or ask for a rubber stamp. For
   related follow-ups, assign a real new turn to the same verified member or
   standalone reviewer; a queued status message alone is insufficient.
7. Collect all findings. Investigate conflicts using the code and repository
   evidence; do not decide by majority vote. Merge duplicates, retain the
   highest severity supported by evidence, and identify the originating lane.
8. Fix Blocking findings before integration tests. Fix Important findings or
   discuss and record an explicit decision before continuing. Advisory findings
   may be accepted at the coordinating agent's discretion but must be recorded.
9. Verify direct review remediations with focused inspection and checks. Do not
   rerun a reviewer merely to confirm that its requested narrow fix was made,
   especially when the fix only deletes rejected behavior or reduces scope.
10. Rerun only the lanes affected when a remediation introduces a new design,
   expands the accepted boundary, changes a public or cross-project contract,
   or resolves a finding through behavior the completed review did not assess.
   Reuse the independent reviewer unless a replacement condition above applies.
   Do not rerun unaffected lanes.
11. Record the risk classification and rationale, reviewer lanes, member
   address or standalone identity, actual model and effort, fallback reason if
   any, reviewed commits, findings, decisions, fixes, and reruns in the
   initiative `state.md`.

## Shared Reviewer Instructions

Review committed changes across all affected projects. Inspect diffs, commit
history, local `AGENTS.md` files, relevant tests, documentation, and project
context before forming conclusions. Review the commit series, not only the
final tree, and compare it with the user request and initiative plan/state.

Stay focused on the assigned lane, but report a concrete serious issue from
another lane if you encounter one. Do not assume that another reviewer will
notice it. Architecture findings must describe a plausible maintenance or
failure scenario instead of relying on pattern names or line counts.

Use these severities:

- `Blocking`: must be fixed before long integration tests.
- `Important`: may proceed only after a fix or an explicit recorded decision.
- `Advisory`: a smaller improvement or residual risk that does not block
  progress.

Start with findings ordered by severity, using file/line and commit references
where possible. If there are no findings, say so clearly and list residual
risks or test gaps. Keep summaries brief; the value of the review is in
concrete findings and compatibility, architecture, and security reasoning.
