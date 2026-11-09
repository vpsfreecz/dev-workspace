# General Review

Review scope, correctness, commit history, tests, and documentation.

## Commit Series

- Verify that the committed changes match the requested feature, bugfix, or
  operational goal.
- Verify that each commit has one logical purpose and is independently
  reviewable. Separate mechanical moves, refactors, behavior changes,
  generated updates, dependency bumps, tests, documentation, and deployment
  changes when they can reasonably be reviewed, reverted, tested, or explained
  independently.
- Treat independently reviewable changes bundled without a convincing
  rationale as `Blocking`, even when the combined final diff is correct.
- Verify any user- or plan-requested commit split. Subject-only commits are
  acceptable only when repository rules allow them or the subject fully
  explains a trivial mechanical change.
- Check that the branch has clean history. Fixup or tidy commits for behavior
  introduced earlier on the same unmerged branch should usually be folded into
  the owning commit unless separation improves reviewability.
- Require an unmerged feature that evolved through multiple designs to
  introduce its final protocol, schema, and behavior directly. Flag superseded
  versions, migrations, dual-read/write paths, or shims kept only for abandoned
  branch iterations. Preserve compatibility with merged, released, deployed,
  or externally consumed behavior.
- For final branch review, compare the complete base-to-head commit list with
  the final diff. Name commits whose approaches were later removed or replaced,
  or explicitly conclude that no obsolete branch history remains. Check that
  follow-up fixes were folded into their owning unmerged commits when
  appropriate. A review of only the latest commit does not complete this gate.
- Require repeated updates to the same flake input, gem dependency, dependency
  group, lockfile, Bundix output, or generated metadata in one update stream to
  be consolidated into one final dependency-update commit. Identify streams by
  dependency, channel/role or input and logical purpose, rather than a shared
  lockfile alone. This applies to generated commits and to feature revisions
  already published or deployed during development.
- Preserve supported deployed behavior and migration lineage without treating
  deployment as an exemption for superseded pin commits. Keep rollout SHAs and
  execution evidence in rollout records. Retain separate updates only when a
  concrete release, supported consumer or state boundary requires them; name
  the boundary and explain why the final update alone is insufficient. Preserve
  any required exact source ref, and respect protections on merged history.
- Independently group the repeated updates in the complete series and assess
  the packet's proposed dispositions. Report superseded commits and their
  consolidation, or the evidence requiring their retention. State explicitly
  when no repeated update streams exist. Treat redundant updates retained
  without that necessity as at least `Important`; an earlier review or the
  label "deployed" or "consumed" is not a sufficient reason to accept them.
- A mechanical-content review exemption does not exempt generated updates
  from consolidation or from an otherwise required whole-branch history review.
- Check commit messages against applicable `AGENTS.md` rules. Messages must
  describe the final result and rationale, not the development process. Do not
  reformat generated messages such as `confctl` commits.

Use these vpsAdmin-specific commit red flags:

- A managed notification-template installer commit must not also add Markdown
  rendering helpers, change Telegram HTML/link rendering, change synthetic test
  notifications, or remove a standalone uploader without an indivisibility
  rationale.
- A notification-delivery rate-limit commit must not also replace route-match
  attribution, change event persistence, expand test-notification authorization
  or scope, or rename generated defaults without an indivisibility rationale.
- Tests, migrations, documentation, and support edits may stay with the
  behavior they support. If they primarily validate another behavior, they
  belong with that behavior.

## Behavior and Coverage

- Check functional correctness, error handling, non-golden paths, and whether
  the implementation follows existing project conventions.
- Check unit/spec coverage, integration coverage across components or daemons,
  and regression coverage for unexpected input, missing or conflicting state,
  rollback/error paths, authorization failures, mixed-version flows, and
  repeated or partially completed operations.
- For tests transferring containers, VPS datasets, backups, or replacement
  datasets, require a known file and contents or equivalent checksum before and
  after the transfer. Metadata-only assertions are insufficient.
- Check that behavior changes update the appropriate documentation, man pages,
  API docs, migration notes, and operational documentation.

## Documentation

Apply the generic dev-session-documentation skill's placement and README
convention, including existing-layout equivalents and repository-local
destinations. Assess the explanation needed by the change; a short rationale
can be enough. Use the existing packet's compact inventory, without requiring
a fixed document bundle, page metadata, historical backfill or another reviewer.
For affected documentation, answer these seven questions with paths/sections
and any exception:

1. Can the intended reader reach the explanation from the README or index, and
   does the README stay an entry point for purpose, basic start and grouped
   links, with any prerequisite or warning needed to start safely?
2. Does each changed passage have the right audience, owner and home:
   reference, how-to, reusable operations, supported upgrade, or individual
   execution? Keep consequential rationale and lasting constraints with their
   owning project. Distinguish application transaction rollback from operations
   that revert deployed software.
3. Would current reference remain useful after the initiative finishes, without
   branch status or private session context? Temporary branch state and one
   rollout's checklists belong in session or locally permitted execution
   records, even without dates or revision hashes.
4. Do commands, behavior, examples and stated verification agree with the final
   source and evidence, distinguishing prepared, tested and deployed claims?
   Keep supported behavior, proposals, historical decisions and inferred
   rationale distinct; disclose unverified instructions and evidence gaps.
5. Have moves preserved every consequential prerequisite, failure or partial
   success condition, compatibility restriction, deployment ordering, data-loss
   warning and recovery step or limit? Split mixed passages without burying
   feature contracts or losing operational safety requirements.
6. Are upgrade applicability and retirement conditions explicit where relevant,
   including source/target versions or state boundaries, old persisted state,
   backup restoration and rollback? Retain supported paths until their owner
   explicitly retires them with evidence; disclose unknown applicability rather
   than treating a completed rollout or missing evidence as permission to retire.
7. Is there one authoritative explanation per contract, with working links and
   anchors, and do prose edits preserve factual meaning and required writing
   rules? Check old entry points when moving content and keep public supported
   guidance accessible without private session records.

Record an explicit documentation placement and preservation conclusion, naming
exceptions and remaining gaps, rather than only "docs checked." If no update
was useful, assess the packet's brief justification. Apply existing finding
severities by consequence: losing a required queue-recovery instruction can
block delivery; a harmless heading preference is advisory. These questions
belong to the existing general lane and do not change review timing or the
exemption for routine planning, investigation, findings, tracking and evidence.

- For KB or DokuWiki changes, manually enumerate instructions that perform a
  vpsAdmin WebUI action and require each to be wrapped in a semantic
  `<vpsadmin-nav>` annotation bound to the affected language pages. A green
  discovery heuristic is not proof of completeness; a missing binding is
  `Blocking`.
