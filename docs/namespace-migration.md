# Namespace migration helper

`vpsfree-dev-workspace-migrate` performs the organization package's one-time,
journaled transition from the former workspace state and runtime paths to the
generic `dev-workspaces` namespace. It is installed in the package's private
`libexec` directory and is not a normal workspace command.

The consuming workspace owns the exact host procedure: package revisions,
workspace roots, session and cluster inventories, service shutdown, system
activation, final acceptance and rollback. That procedure must use a
compatibility package configured with the source user namespace and router
socket, stop every managed session and tmux process, and run both scope
preflights before either forward mutation.

The generic invocation shape is:

```sh
set -Eeuo pipefail

FINAL_PACKAGE=/nix/store/exact-dev-workspace-package
REGISTERED_WORKSPACE=/absolute/path/to/registered-workspace

"$FINAL_PACKAGE/libexec/vpsfree-dev-workspace-migrate" preflight \
  --direction forward --scope user --workspace-root "$REGISTERED_WORKSPACE"
sudo "$FINAL_PACKAGE/libexec/vpsfree-dev-workspace-migrate" preflight \
  --direction forward --scope host

"$FINAL_PACKAGE/libexec/vpsfree-dev-workspace-migrate" forward \
  --scope user --workspace-root "$REGISTERED_WORKSPACE" --yes
sudo "$FINAL_PACKAGE/libexec/vpsfree-dev-workspace-migrate" forward \
  --scope host --yes
```

The preflights acquire the same transition locks as mutation, validate all
source and destination trees together, and do not create journals or move
state. Keep the inventoried state frozen between preflight and completion. A
forward retry uses the same command and resumes the private journal.

The deployment-specific stop-and-recreate procedure does not use the helper's
retained-tmux compatibility path. Runtime authorities and the tmux socket must
be absent before forward preflight. Persisted tracking, worktrees, active and
archived portal manifests, registry data, profile generations and Codex data
remain on disk. The consuming procedure must audit which active sessions own a
Codex thread and prove each recorded thread is materialized before any live
mutation. Shell-only sessions remain shell-only; archived sessions are stopped
but not recreated.

## Rollback

Close browser admission and stop only authorities proven to belong to the
reviewed session inventory. Stop the portal, App Server, reconciler and tmux
keeper, and prove both the destination authority directory and socket are
empty. A partially completed forward operation must first be retried to a
complete journaled result. Then run both reverse preflights before either
reverse mutation:

```sh
set -Eeuo pipefail

"$FINAL_PACKAGE/libexec/vpsfree-dev-workspace-migrate" preflight \
  --direction reverse --scope user --workspace-root "$REGISTERED_WORKSPACE"
sudo "$FINAL_PACKAGE/libexec/vpsfree-dev-workspace-migrate" preflight \
  --direction reverse --scope host

"$FINAL_PACKAGE/libexec/vpsfree-dev-workspace-migrate" reverse \
  --scope user --workspace-root "$REGISTERED_WORKSPACE" --yes
sudo "$FINAL_PACKAGE/libexec/vpsfree-dev-workspace-migrate" reverse \
  --scope host --yes
```

The user helper accepts either the exact recorded compatibility generation as
current or the final generation with that compatibility generation immediately
behind it. Reverse retry uses the same command and journal. After both scopes
are restored, the consuming procedure selects its recorded old system and
profile generations, recreates the reviewed sessions through the restored
helper, verifies exact authority identity, and only then reopens its old
router.

Keep host writers that can change the recorded credential, CA, certificate or
TLS trees stopped from forward host preflight through forward acceptance or
completed rollback. Schema 5 is the first deployed journal format; no older
journal schema is accepted. A retry tolerates a rename or rewrite that reached
durable storage immediately before its journal update, but it never accepts an
unrecorded file, path, owner, mode, symlink target or content change.
