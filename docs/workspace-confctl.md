# Workspace confctl adapter

`workspace-confctl-adapter` implements the generic runtime's
[coordination adapter contract](https://github.com/aither64/dev-workspace/blob/master/docs/coordination.md).
The consuming workspace supplies exact machine selectors and repository mappings.
This extension stores no concrete deployment hosts or credentials.

`resolve-machine` reads the metadata used to derive a configured machine's logical
identity from an exact committed revision. The runtime supplies its registered Git
source, revision and exact selector through this protocol-1 request:

```json
{"schema":1,"operation":"resolve-machine","selector":"standalone/host.example.test","source":{"path":"/owned/configuration.git","revision":"EXACT_40_HEX_COMMIT"}}
```

The response contains only `schema`, the exact configured `name`, and
`sharedLockId`. An absent `metaConfig.labels."dev-workspace.lock-id"` produces
`sharedLockId: null`. A present label must be valid UTF-8, contain 1–256 bytes,
and have no control characters or leading or trailing whitespace. The adapter
refuses explicit null, empty or malformed labels. The runtime derives the claim's
identity, resource key and display name; the adapter supplies only metadata.

Resolution evaluates the selected `confctl.machines` entry locally and offline,
with import-from-derivation and lock updates disabled. It does not build
`machinesJson`, prepare a generation, copy closures or contact the machine.
Prepare missing locked inputs through the ordinary configuration workflow before
requesting a claim. Resolution accepts any exact configured machine name and does
not apply the deployment operation's machine-type restrictions.

`lib.mkPackage` accepts optional `machineIdentityConfig` and passes a supplied
policy to the runtime. Leaving it unset or null omits the underlying runtime
argument, preserving compatibility with providers that do not accept it.
The consuming workspace owns the profile target and legacy compatibility mappings;
ordinary new machines need no catalog entry.

Deployment supports one standalone NixOS machine, action `switch`, and no reboot.
It rejects carried machines and selectors that do not resolve exactly. Requests
use strict schema-1 JSON on stdin; stdout contains one complete JSON response.
Diagnostics are private bounded logs.

Preparation builds an immutable confctl environment from the configuration's
exact committed flake and uses its public Ruby APIs. It evaluates the machine
once, builds a named generation and copies its exact system/rollback closures.
The artifact retains generation metadata/digest, effective inputs, evaluated
machine mapping, and environment package. The runtime keeps their GC roots.

Activation loads those retained values without Nix evaluation, build or copy.
It uses the public stateless Nix client so a fresh process does not evaluate
confctl settings through the default constructor.
Under the runtime's machine claim/reservation it checks both running system and
system profile, performs dry activation, repeats the baseline check, runs the
configured switch/auto-rollback, publishes the profile and verifies both links.
It records separate intent/publication/result receipts. Release ownership under
the runtime's machine-retention rule once deployment effects are verified and
the deployed lineage is integrated into approved defaults. Follow-up UI review
can continue afterward.

`inspect` reads the running system and system profile. `reconcile` requires a
verified original receipt and matching live identities before declaring success.
A partial publication,
lost SSH reply or baseline-looking system after uncertain rollback remains
`unknown`; neither process exit nor link equality proves the remote attempt
finished. An uncertain attempt requires operator recovery. `transition-check`
validates retained protocol and
generation identity without selecting a system.

`lib.mkPackage` accepts optional `coordinationConfig` and injects this adapter's
immutable executable. The adapter uses the selected generic runtime's pure Ruby
command runner for bounded protocol capture and diagnostics. Other extension,
session, KB and cluster formats remain unchanged. Concrete operations and first
installation belong in the consuming configuration/workspace documentation.
