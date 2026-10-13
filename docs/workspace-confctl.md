# Workspace confctl adapter

`workspace-confctl-adapter` implements the generic runtime's
[coordination adapter contract](https://github.com/aither64/dev-workspace/blob/master/docs/coordination.md).
The consuming workspace supplies exact machine selectors and repository mappings.
This extension stores no concrete deployment hosts or credentials.

The adapter supports one standalone NixOS machine, action `switch`, and no reboot.
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
It records separate intent/publication/result receipts. Health checks and human
UI review continue while the durable reservation remains owned.

`inspect` reads both identities. `reconcile` requires a verified original receipt
and matching live identities before declaring success. A partial publication,
lost SSH reply or baseline-looking system after uncertain rollback remains
`unknown`; neither process exit nor link equality proves the remote attempt
finished. The first release conservatively requires operator recovery rather
than blindly replaying it. `transition-check` validates retained protocol and
generation identity without selecting a system.

`lib.mkPackage` accepts optional `coordinationConfig` and injects this adapter's
immutable executable. The adapter uses the selected generic runtime's pure Ruby
command runner for bounded protocol capture and diagnostics. Other extension,
session, KB and cluster formats remain unchanged. Concrete operations and first
installation belong in the consuming configuration/workspace documentation.
