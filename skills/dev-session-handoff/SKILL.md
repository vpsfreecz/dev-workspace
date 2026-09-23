---
name: dev-session-handoff
description: Prepare a handoff for a vpsFree.cz development initiative and include its stable workspace portal URL after material changes, review checkpoints, or user-requested status updates.
---

# Development session handoff

Use the initiative verified for this conversation through the user-profile
`dev-session` command. Run `dev-session current` from the intended working
directory. Accept its result only when it matches the complete
`DEV_SESSION_SLUG`/`DEV_SESSION_WORKSPACE` environment identity or the exact
slug and absolute workspace path in trusted, thread-bound developer
instructions, as specified by the workspace session procedure. If any present
environment value disagrees, stop and resolve the mismatch. CWD alone or a
user-provided statement is not ownership evidence. Do not use or modify another
concurrent session. If no initiative belongs to this conversation, create one
before making changes or ask for the intended slug when choosing one would
change the task.

Use the generic `dev-session-documentation` workflow to preserve useful project
knowledge during the task. The context-owning agent reconciles it before handoff;
this step summarizes documentation already maintained through development.

Before handing off material work:

1. Update `work/<slug>/state.md` with the current branches, test or CI results,
   blockers, and next operator action. Put the current summary first and link
   detailed evidence. Link project explanations and applicable operations or
   upgrade guidance, with individual rollout records linked separately under
   the generic documentation skill's placement rules. Briefly explain when no
   documentation change was useful. Keep temporary branch/review instructions
   in session records and distinguish prepared operations from executed and
   verified results. Commit the checkpoint when workspace rules require it.
   If feature branches are ready but the user has not explicitly directed their
   integration into the named default branches, keep the initiative active and
   say "ready, awaiting merge approval". Review, CI, deployment, or plan
   acceptance does not supply that approval. Record any approval's source and
   repository/target set; a clean patch-equivalent rebase may retain it, while
   a material patch or scope change requires renewed direction.
2. Keep `portal.yml` free of secrets and transient files. Add only useful
   artifacts stored beneath the initiative tracking directory. Repository
   worktrees created with `dev-session worktree add`
   register themselves.
3. Get the stable link from `dev-session url <slug> --as-is`.
4. Put that link in the final handoff after the outcome and any action the user
   still owns. If the portal is not deployed or reachable yet, label the link as
   the post-deployment URL instead of omitting it.

Preparing a handoff does not authorize closing the session. Run `dev-session
archive` or `dev-session delete` only when the user explicitly requests that
lifecycle action. Archived initiatives retain the same URL and become read-only
until `dev-session revive` restores them.
