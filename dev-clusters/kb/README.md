# Managed KB clusters

Set `siteConfig.clusterDefaults.kb` to an immutable JSON configuration file to
include the `kb` provider in the workspace package. A registered workspace can
then select `kb` in `.dev-workspace.json`. Omitting the configuration preserves
the existing provider set.

The package selects one exact published KB runtime revision for the launcher,
source receipt and read-only validators, with the runtime's own input graph.
The [portable runtime contract](https://github.com/vpsfreecz/vpsfree-kb-contracts/blob/master/cluster/runtime-contract.md)
owns lifecycle, prepared artifacts, source verification, resources and capture
behavior. This adapter binds that engine to a workspace and session and
delegates lifecycle and live checks to its fixed packaged executable.

## Commands and retained state

Use `kb-devcluster --workspace NAME COMMAND SLUG`. The public dispatcher holds
the selected package generation throughout the command. Mutations and captures
require an active session without unfinished lifecycle journals. Contention on
a session, adapter or portable gate returns busy exit code `75`.

Managed bindings live under `.dev-clusters/kb/bindings/SLUG`; the portable engine
owns `.dev-clusters/kb/clusters/SLUG`. A binding records the engine revision at
creation and retains it across compatible package transitions. Transition
adoption validates management compatibility. Capture still requires a prepared
artifact matching the selected source, and resume and update keep the portable
runtime's prerequisites. Unbound or legacy state is refused.

## Capture connections

`connection SLUG` exports a private managed descriptor. It preserves the
canonical source, artifact, endpoints and credential references and changes
only the controller route to the public `kb-devcluster` command. Pass this
descriptor to the shared capture engine with
`vpsfree-kb-capture --connection /private/connection.json` and the capture
selection options described in the portable guide.

The adapter validates the current descriptor and canonical readiness, then
translates only the descriptor digest in the readiness response. The portable
engine's canonical descriptor stays intact.

Canonical readiness uses the selected engine's `ready?` predicate, including
the exact run-ready marker. A live runner that is draining its guests cannot
export a capture connection. The portable lease rechecks readiness after guest
attestation and while held. Inventory and compatible management retain their
separate live-or-proven-exit rules; they do not grant capture readiness.

The lease holds generation, session, adapter and portable guards throughout
capture. Protocol stdout loss ends the lease; diagnostic stderr EOF alone leaves
it active. Peer or dispatcher loss closes child input, and cleanup reaps the
exact spawned child. The portable child receives mediated pipes and cannot
retain the original peer channels or outer authority descriptors.

## Removal inventory

`cleanup-paths SLUG` reports verified owned instance, binding and recorded socket
paths. It can inspect running, stopped or pending state using noncreating reads;
the inventory grants no cleanup authority or proof that processes exited. The
generic removal workflow already holds the session lock, so this query does
not reacquire it. Reset is a separate guarded operation delegated to the
portable engine, with its normal process-exit and capture-exclusion checks.

Focused tests cover synthetic CLI and pipe boundaries separately from readers
of the actual selected runtime snapshots. Guest behavior, package activation
and installed managed capture require their own verification after committed
independent review.
