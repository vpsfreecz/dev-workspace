# vpsAdmin Dev Clusters

The installed `vpsadmin-devcluster` command runs vpsAdmin development clusters
from feature worktrees under `worktrees/<slug>/`. Run it from the registered
workspace or pass `--workspace NAME` before the command.

Runtime state, certificates, SSH keys, result links, and logs are stored under
`.dev-clusters/` at the workspace root and are intentionally not tracked by git.

The selected vpsAdminOS source must provide OSVM's per-disk `preserve` setting,
`rootDisk` descriptors, `overlays.all` and `vpsadminosRubyGemConfig`. The runner
checks the disk API before constructing any VM. Update older selected OS
sources before starting the cluster. Existing complete VM disk images need no
conversion.

Services and DNS root disks are retained across stop/start. Apply configuration
changes with `update` while the VMs are running so their root disks contain the
new system closures before the next boot. Starting retained disks with older
runner versions can replace them with fresh images and erase their data.

## Maintenance boot for retained disks

When the cluster is stopped and the required services closure has not been
copied into its retained disk, use a recorded resident configuration to boot
services with application writers held from initial boot. This requires the
maintenance-aware provider and runtime transition policy 3. Keep a private
database backup and positive evidence that the exact services closure is
resident before beginning. A selected build or stale ready file does not prove
residency.

```sh
vpsadmin-devcluster maintenance-start <slug> \
  --resident-config /nix/store/recorded-config \
  --expect-services-toplevel /nix/store/recorded-services \
  --residency-evidence /private/residency-evidence.json
vpsadmin-devcluster update <slug> services --copy-only
vpsadmin-devcluster stop <slug>
vpsadmin-devcluster start <slug> --copied-config
```

The evidence file must be an operator-owned regular file with mode 0600,
without a symlink, and at most 8 KiB. Its version-1 JSON has exactly these
fields:

```json
{
  "version": 1,
  "workspace": "/absolute/registered/workspace",
  "slug": "bound-session-slug",
  "resident_config": "/nix/store/recorded-config",
  "resident_config_sha256": "64-lowercase-hex-digits",
  "services_toplevel": "/nix/store/recorded-services",
  "evidence_kind": "prior_copy",
  "evidence_reference": "private operator evidence reference"
}
```

Use SHA-256 of the exact configuration bytes. `evidence_kind` accepts
`prior_activation`, `prior_copy` or `cold_residency`. The reference records
trusted operator evidence; the helper does not open the referenced artifact.
The helper bounds strings to 2048 bytes and the slug to 128 bytes. Retry must
use the same evidence bytes and resident selection; moving an identical file
is allowed. Status omits its private reference and paths.

Maintenance requires the existing owned bridge cluster, no live runner or
socket processes, and all retained managed disks present with positive size
and `preserve=true`. It starts only services. Fixed kernel masks hold the API,
seed, scheduler, supervisor, application containers, ingress and timer graph.
SSH, MariaDB and the Nix daemon remain available. MariaDB recovery and ordinary
OS bookkeeping can still write; this hold does not establish storage quiet or
repair authority. Unknown writers, activation triggers, boot parameters or
generator evidence refuse the boot. The helper passes no arbitrary kernel
parameters and checks the complete command line against its supported bound.

Copy-only requires the proved masks and the same runner and guest boot identity.
The candidate must carry the provider's exact preserving-seed contract:
`labels.vpsadminPreservingSeed` is the JSON string
`{"version":1,"existingAssignments":"preserve"}`. The enabled profile must
emit it from the selection that actually preserves existing assignments.
An old or disabled seed without this marker refuses copy. The marker does not
replace the separate API schema, scheduler and plan compatibility checks.

Copy-only verifies the complete guest closure and executable `init`, retains a
guest GC root, then records a matching next configuration. It does not activate
the closure, restart units, refresh nodes or load the API. The next configuration
changes only services and keeps every other guest entry, network, mount and
disk layout. A rebuilt services root image may have a different **source**
`rootDisk.image`; its retained destination and every other disk field stay
exact. The helper rechecks disks before machine construction and immediately
before each start. A missing disk refuses boot before OSVM can create an image.

The copied-config boot uses the recorded configuration without rebuilding it.
It releases the hold only after the new seed has run successfully, API and
supervisor are active, and the normal node refresh completes. Pending or
unknown maintenance state blocks plain start, update, refresh, restart and
reset. Status and stop remain available. Private hold/copy records and their
configuration GC roots survive stop and interruption. Failed copy has no
release receipt; stop and retry the same proved maintenance selection or
diagnose while stopped. If a new boot may have changed schema or state, verify
compatibility before selecting an old resident generation for masked recovery.
Never reset retained state or run an old package to evade a refusal.

Runtime policy 3 permits the supported forward transition from policy 2 with
schema 1. It conservatively rejects normal transitions to policy 2 while any
development-cluster state exists, even after maintenance completes. Recover
with a reviewed compatible package. Old candidate recovery helpers cannot
prove this maintenance state and are outside the supported procedure.

For focused provider tests, use the pinned Ruby in the repository root. The
provider has no development shell. Select its canonical runtime contract and
run each fixture in a separate process. Use the pinned Ruby's bundled gems so
an inherited user gem directory cannot replace its Minitest version:

```sh
export DEVCLUSTER_RUNTIME_CONTRACT="$(nix eval --raw --impure --expr \
  '(builtins.getFlake (toString ./.)).inputs.dev-workspace.lib.runtimeContract')"
nix shell --inputs-from . nixpkgs#ruby nixpkgs#bash nixpkgs#coreutils \
  nixpkgs#git nixpkgs#jq nixpkgs#openssl nixpkgs#util-linux -c bash -ec '
    unset RUBYOPT
    export GEM_HOME="$(ruby -rrubygems -e "puts Gem.default_dir")"
    export GEM_PATH="$GEM_HOME"
    for name in maintenance runner commands status; do
      ruby "test/devcluster_${name}_test.rb"
    done
  '
```

The normal flake test check also runs these fixtures. They do not boot a guest;
generator masks, seed preservation and copy/restart interruption require the
separate disposable VM acceptance check after review.

## Basic Usage

```sh
vpsadmin-devcluster start 2026-05-29-security-advisories --topology dual
vpsadmin-devcluster urls 2026-05-29-security-advisories
vpsadmin-devcluster config 2026-05-29-security-advisories
vpsadmin-devcluster refresh 2026-05-29-security-advisories
vpsadmin-devcluster update 2026-05-29-security-advisories services
vpsadmin-devcluster ssh 2026-05-29-security-advisories services
vpsadmin-devcluster stop 2026-05-29-security-advisories
vpsadmin-devcluster gcroots --cleanup
```

When running inside a `dev-session` shell, `ssh` can use
`DEV_SESSION_SLUG` automatically:

```sh
vpsadmin-devcluster ssh node1
vpsadmin-devcluster ssh services -- hostname
vpsadmin-devcluster ssh node1 -t -- bash -l
```

Topologies:

- `single`: services VM and one vpsAdminOS node.
- `dual`: services VM and two vpsAdminOS nodes.
- `storage`: services VM, two regular nodes, and one storage node.

Only one VPN-visible dev cluster should be active at a time. The cluster uses
the existing the development host dev-network names and IPs, especially
`webui.staging.example.test`. The `*-tmp.staging.example.test`
names are configured as secondary frontend entries for internal/maintenance
access tests.

Network modes:

- `bridge` is the default. It attaches VMs to `br0` and uses the predictable
  `172.16.106.*` dev addresses. The current user needs access to `/dev/kvm` and
  a usable `qemu-bridge-helper`. On the development host, deploy the host configuration
  that provides `/run/wrappers/bin/qemu-bridge-helper` and keeps
  `/etc/qemu/bridge.conf` restricted to the allowed bridges.
- `local` runs without bridge privileges. VMs talk to each other on a QEMU
  socket network and expose host forwards on localhost:
  `10443` for HTTPS, `10022` for services SSH, `10122` for node1 SSH, `10222`
  for node2 SSH, and `10322` for storage1 SSH.

The bridge helper path defaults to `/run/wrappers/bin/qemu-bridge-helper`.
Override it with `VPSADMIN_DEVCLUSTER_BRIDGE_HELPER=/path/to/helper`, or set it
to an empty value to omit the QEMU `helper=` option.

`start` and `update` keep the built cluster config rooted at
`.dev-clusters/vpsadmin/clusters/<slug>/result-config` while the cluster is in
use. `stop` removes that root after the runner exits, and `reset` removes it
with the rest of the cluster state. Use `vpsadmin-devcluster gcroots` to list retained
cluster config roots and `vpsadmin-devcluster gcroots --cleanup` to remove roots for
stopped clusters left by older tooling.

Resolver behavior is configured in `config.json` under `resolver`. The default
mode, `cluster`, runs dnsmasq on the services VM, serves all devcluster host
records from the same config, and forwards other lookups to configurable
upstream nameservers. The default upstreams are the vpsFree.cz internal
resolvers `172.16.9.90` and `172.19.9.90`. Other supported modes are
`upstream`, which points every VM directly at `resolver.upstreamNameservers`;
`gateway`, which points every VM at `network.gateway`; and `none`, which leaves
the machine defaults alone.

## Configuration And Seed Data

Each cluster gets its own editable config at:

```sh
.dev-clusters/vpsadmin/clusters/<slug>/config.json
```

The package receives its defaults from the consuming workspace through
`siteConfig.clusterDefaults.vpsadmin`. On first use, the helper copies them to
the cluster config. Nix merges this config over the packaged defaults, preserving
per-cluster overrides. Use it to change domains, service and node
IP addresses, topology membership, seeded users, resource packages, pool
settings, networks, IP addresses, and mail recipients.

The default seed creates:

- one hypervisor pool on each regular node, using filesystem `tank/ct`;
- public and private IPv4 networks with allocatable addresses;
- two non-admin users, `test-user1` and `test-user2`;
- default VPS resource values and per-user resource packages;
- mail recipients for admin daily reports;
- vpsfree mail templates, when the matching worktree exists;
- Adminer database browser, exposed as
  `https://adminer.staging.example.test/`;
- vpsFree.cz web, exposed as `https://web-cs.staging.example.test/`
  and `https://web-en.staging.example.test/`, when the matching
  worktree exists;
- a vpsf-status instance on the services VM, exposed as
  `https://status.staging.example.test/`.

### Storage profile

The storage topology can enable representative member NAS and VPS backup
policy through the cluster configuration:

```json
{
  "storageProfile": { "enable": true, "enrollment": true }
}
```

`enrollment` defaults to `true` and must be a boolean. The enabled profile
preserves existing namespace allocations/maps, personal packages and effective
resource assignments on repeat seed runs. Incompatible accounting or ambiguous
ownership refuses the update. Missing namespaces are allocated after services
and nodes are ready, through normal API chains. The disabled profile retains
the ordinary fixture seed behavior.

The profile uses the regular hypervisor pools as sources and creates separate
`tank/backup` and `tank/nas` roots on the storage node. Both have an initial
limit of 32 datasets. They share the same physical zpool. Provision checks
catalog and physical root presence before Pool creation and refuses adoption
of an uncatalogued root. Pool capacity must have fresh allocation evidence.

Future active level-1 members receive a shared package with 4 CPUs, 4096 MiB
memory, 2048 MiB swap, 8192 MiB disk space, four public IPv4 addresses and
16 private IPv4 addresses. Their NAS root has a 1024 MiB quota. Existing users
keep their entitlement; catch-up reports insufficient resources rather than
changing a personal package. Administrative/service accounts receive no
automatic member NAS allocation.

After the compatible services generation and Node workers are running, use:

```sh
vpsadmin-devcluster storage-profile <slug> provision
```

Provision creates missing configured roots through normal Pool chains, waits
for readiness, commits shared empty snapshot templates, then enrolls existing
members and confirmed sources. Its initial admission observation completes in
a short database transaction. Each chain and template writer checks admission
again in its own staging transaction; physical waits hold no database
transaction or freeze lock. A later freeze refuses subsequent work and retains
previously committed chains and their evidence.

Newly profile-created sources use minimum 2, maximum 3 snapshots and maximum
age 1800 seconds; new backup copies use minimum
2, maximum 5 and maximum age 3600 seconds. These are rotation targets after
successful Backup, not hard growth or physical-space bounds. Failed or locked
work and snapshot dependencies can retain more history. Existing source
retention stays unchanged. Catch-up does not Rotate; later normal Backup may
prune under that unchanged policy. A new backup copy uses only its own
dataset-create command; existing logical Dataset rows and shared templates do
not belong to that command's rollback.
Snapshot tasks use `*/5` minutes and backup tasks use `2-59/10`. Enabled
profile scheduling reloads tasks every 60 seconds. The selected API must
support interval syntax and retained shared templates before enrollment.

To retire, keep the overlay enabled and select `enrollment: false`. Complete
the supported services update/restart so every API, supervisor and scheduler
process has loaded that selection, then run:

```sh
vpsadmin-devcluster storage-profile <slug> retire
```

The loaded helper reports its enrollment value; a desired/deployed mismatch
refuses the command before effects. Editing the host config alone is not a
services restart. Retired boot still preserves existing assignments and the
preserving-seed marker. Static bootstrap only removes the exact owned future
default-package link, including while storage is read-only. It creates no
package/default and changes no Environment permissions or existing allocation.
Hooks skip new enrollment, and explicit provision, template creation, catch-up
and direct Plan add/verify refuse. Normal Plan removal remains available.

Retirement stops dispatch, requires admitted work to have settled, and removes
only owned memberships, actions/tasks, templates, Environment plan links and
the future default link in an atomic configuration transaction. It preserves
the Plan definition, all packages/assignments and storage catalog/payloads.
Remaining owned rows indicate pending retirement. Success resumes unrelated
scheduling; failure keeps the scheduler stopped and evidence available for
diagnosis. Repeating retirement or a services seed does not reactivate the
profile. Never disable the overlay on retained disks to retire or recover.
Re-enrollment requires a compatible services generation with enrollment true,
then provision. These operations do not establish quiet or repair authority.

### Storage profile verification

The optional no-VM smoke selection evaluates active and retired profile
closures, their preserving-seed marker and invalid selections. Override the
API input with the compatible source being tested; setting only a launcher
source environment variable does not replace the imported Nix module:

```sh
nix run --no-write-lock-file \
  --override-input devcluster-vpsadmin path:/absolute/compatible/vpsadmin \
  .#devcluster-check -- --storage-profile
```

The real database helper specs use that API's test environment and disposable
database. Run the wrapper from its `.#api` shell, which already enters `api/`.
It refuses an inherited `DATABASE_URL` or a configured database and controls
RSpec's options so the guard runs before schema loading:

```sh
nix develop /absolute/compatible/vpsadmin#api -c \
  /absolute/provider/dev-clusters/vpsadmin/tests/run-storage-profile-api-specs.sh
```

After committing and reviewing the provider, the explicit retained-services
fixture boots one disposable services guest across old, held and copied
generations. Its configuration arguments are fixed by the app; it accepts only
an optional new artifact directory. It checks real seeds, generator masks,
writer-start counters, interrupted copy/boot recovery and retained assignments
and payload. It keeps the hold at `starting_copied`: services-only coverage
cannot prove the full cluster's Node refresh or release.

The app evaluates and builds its two fixed fixture configurations only when
invoked, carrying the selected input sources and their declared follows into
that build. Ordinary flake checks keep the disabled default API selection.
An invocation without a compatible API override refuses the enabled candidate
configuration before starting a guest. The native runner receives only the
built store JSON files.

```sh
nix run --no-write-lock-file \
  --override-input devcluster-vpsadmin path:/absolute/compatible/vpsadmin \
  .#devcluster-maintenance-check
```

The fixture retains private failure artifacts and stops only its own guest.
It does not replace registered cluster disks. The existing
`host-migration-test` remains a separate required check for runtime policy
compatibility; neither fixture proves the other's contract.

The payload fixture runs against an explicitly selected, owned storage
cluster after its compatible services generation and profile provision are
ready. It requires read-write storage, a running scheduler, an active seeded
`test-admin`, and an enabled compatible OS template. Run its host script with
a new private artifact directory:

```sh
ruby dev-clusters/vpsadmin/tests/storage-profile-acceptance.rb \
  --slug <bound-session-slug> --artifact-dir /private/new-profile-fixture \
  --os-template-id <enabled-template-id>
```

Enabled services package the fixed `vpsadmin-storage-profile-acceptance`
guest wrapper from the same profile selection as the preserving seed. The
host script uses public provider SSH, provision and services-update commands;
the guest wrapper invokes only its packaged fixture through the ordinary
database task. It accepts no arbitrary script path and exports no credentials.

The fixture creates its own member, VPS and NAS child through normal chains.
Immediately before each payload write, a fresh guest `info` request checks
read-write mode, settled evidence and the bound source/destination routing.
The trial requires no concurrent operator freeze change during these direct
file writes: the observation is not an atomic interlock across DB and SSH.
It writes only those new objects, verifies full and incremental sends, and
checks both historical payload versions through normal `UseClone` read-only
views. Each view must have `readonly=on`, matching checksums and the expected
file absence. Cleanup uses normal `FreeClone` and `RemoveClone` operations
restricted to that returned, owned clone ID; it never runs the global inactive
clone sweep. Rotation and an actual scheduled cycle check the configured
retention targets and a common base for both cross-node VPS and same-node NAS
copies. Repeat provision and services seed must preserve other users'
allocations and task identities.

The host prints a numeric summary and keeps mode-0600 IDs, projections and
diagnostic files in private mode-0700 artifact directories. Guest failures
retain private mode-0700 diagnostic directories with chain and object IDs
recorded before waiting. A timeout or failure does not cancel admitted chains,
delete fixture objects, change storage mode or reset disks.
Inspect that evidence before retrying; scheduling may remain stopped. Successful
fixtures remain available for inspection and do not establish storage quiet,
repair readiness or APPLY authority.

### Optional React Web UI

The legacy PHP Web UI remains available. A separate React Web UI runs on the
services VM when the cluster config enables it:

```json
{
  "newWebui": { "enable": true },
  "domains": { "newadmin": "newadmin.devhost.example.test" }
}
```

Use a distinct DNS name for `domains.newadmin`. The React service is disabled
when these settings are absent. Enabled clusters require bridge networking;
`start` and `update` reject an enabled local cluster. The public TLS endpoint
proxies to the new container's private nginx on loopback port 18082. Its OAuth
BFF listens on loopback port 3001 inside that container. The
container uses the cluster CA to validate its HTTPS calls to the auth service.

The enabled service uses API version 7.0 and a separate, nondefault OAuth
client with 20-minute access tokens and 30-day refresh tokens. Its callback is
`https://<newadmin-domain>/oauth/callback`; the PHP client's default status,
credentials and service are retained. The new container keeps BFF sessions in
its own persistent `/var/lib/vpsadmin-webui/sessions` directory.

The first enabled build generates an OAuth client ID, client secret and session
secret under
`.dev-clusters/vpsadmin/clusters/<slug>/webui-credentials/`. It keeps that
bundle across `stop`, `start` and services updates. An incomplete, malformed or
unexpected bundle stops the build; the launcher does not replace or rotate it.
The credentials enter the services VM through a dedicated runtime mount and are
never copied into Nix source or cluster status. Cluster reset remains a
separate destructive operation under the normal session rules.

The packaged WebUI source is pinned to reviewed revision
`534caa83a5f97d2b40b4a126886649b14dc9e8d3`. If the same session owns
`worktrees/<slug>/vpsadmin-webui`, the launcher uses that source instead and
records its revision and dirty state in `status --json`. Both frontend and BFF
packages come from that input and must have matching provenance. Changes to a
local WebUI worktree require `update <slug> services`; there is no live Vite
process in the VM. The cluster's selected vpsAdmin worktree supplies the API,
and the packaged smoke check pins a compatible API revision.

The selected `result-config` JSON records the WebUI source revision, dirty
state, and whether it came from the pinned input or a session worktree. Status
reports those values from that selected build, even if `config.json` changes
afterward. It does not confirm that the services VM has activated the build.
Older `webui-source.json` files are ignored. A build with only the former
revision and dirty labels must be rebuilt to record its source kind.

The plugin set is configured with `plugins.enabled`. The default value is
`"all"`, which enables every plugin directory bundled in the selected vpsAdmin
worktree. Set it to a JSON array such as `["webui", "payments"]` to test a
smaller set, or to `"none"` to disable plugins.

Regular devcluster nodes set nodectld's `zfs_send` and `zfs_recv` queue
`start_delay` to `nodectld.zfsTransferStartDelay`, which defaults to `0`.
This avoids production transfer pacing during manual migration, clone, backup,
and VPS replacement testing. Set it in a cluster config only when the delay
itself is what you need to test.

After a services seed has changed pool data, `devcluster refresh <slug>` prepares
the vpsAdmin pool working directories and default pool device grants on regular
nodes, then restarts nodectld so DB-seeded pools are usable by node transactions.
`start` and `update ... services` run the same refresh automatically.
Refresh waits up to two minutes for SSH on each machine before checking the seed
or preparing a node. Probes cannot prompt for credentials; a stalled probe fails
after five seconds. A failed remote action stops refresh immediately.
On each node, refresh also waits up to three minutes for the pool to be imported
in ZFS and active in osctld before preparing directories and granting devices.

Example local start:

```sh
vpsadmin-devcluster start 2026-05-29-security-advisories --topology single --network local
```

For browser testing in `local` mode, resolve the printed dev hostnames to
`127.0.0.1` and use port `10443`, for example
`https://webui.staging.example.test:10443/`.

## HTTPS

`start` ensures a certificate set exists. By default, it generates a
workspace-local CA and leaf certificate. To reuse an existing CA and server
certificate, import a directory containing `vpsadmin-ca.crt`,
`vpsadmin-ca.key`, `vpsadmin-cert.crt`, and `vpsadmin-cert.key`:

```sh
vpsadmin-devcluster cert import /path/to/certs
```

Set `VPSADMIN_DEVCLUSTER_CERT_IMPORT_DIR=/path/to/certs` to have `start`
import an existing certificate set automatically when the cluster has no
certificate yet. When the configured domains change, the helper reissues the
leaf certificate from the current CA. If the current CA key is encrypted and
cannot sign unattended, it falls back to a fresh workspace-local CA. Set
`VPSADMIN_DEVCLUSTER_CA_PASSPHRASE` before `start` or `update` to reissue from
an encrypted imported CA instead.

Use:

```sh
vpsadmin-devcluster cert show-ca
```

to print the CA certificate path and fingerprint for browser trust setup.

## Email

Outgoing vpsAdmin mail is captured by Mailpit in the mailer container. The
Mailpit UI is exposed through the services nginx frontend at the HTTPS URL
printed by `devcluster urls`, currently
`https://mailpit.staging.example.test/`, and is protected with the
configured development basic-auth credentials. The raw Mailpit HTTP listener is
bound to `127.0.0.1` inside the services VM.

If `worktrees/<slug>/vpsfree-mail-templates` exists, its templates are copied
into the Nix closure and used as vpsAdmin's complete notification-template
source. The notification-template service reconciles them after database setup
before the repeatable development seed attaches configured mail recipients.
Both steps complete before the API or supervisor starts. Re-run:

```sh
vpsadmin-devcluster update <slug> services
```

after changing template files or the cluster mail config. Runtime virtiofs
mounts cannot be added to an already-running VM, so templates are intentionally
closure-copied instead of mounted live.

Template installation requires vpsAdmin commit `cbd0fa16` or a compatible
newer revision with authoritative notification-template mode, plus the template
repository's declarative `templates/` layout. Nix evaluation stops with an
error when the paired worktrees are incompatible. To run an older vpsAdmin and
template pair, set `mail.templates.install` to `false` in the cluster's
`config.json`. The cluster then uses vpsAdmin's bundled defaults without
reconciling the external worktree.

## Database Browser

Adminer runs on the services VM and is exposed through the same nginx HTTPS
frontend as the Web UI, API, Mailpit, and status page. The default basic-auth
credentials are printed by `devcluster urls`.

Use `MySQL`, server `127.0.0.1`, user `vpsadmin`, and password
`testMariadbApiPassword` to browse the vpsAdmin database.

## Status Page

vpsf-status runs on the services VM and is exposed through the same nginx HTTPS
frontend as the Web UI, API, and Mailpit. If `worktrees/<slug>/vpsf-status`
exists, it is used as the source for the status package. If
`worktrees/<slug>/vpsadmin-go-client` exists, it is made available to that
package for local generated-client testing.

Re-run:

```sh
vpsadmin-devcluster update <slug> services
```

after changing vpsf-status or the generated Go client.

## Runtime Updates

The web UI is served from a live symlink tree backed by the selected vpsAdmin
worktree, with Composer/vendor dependencies coming from the Nix package.
Changes to existing PHP/templates/static files are visible after normal
PHP-FPM/nginx behavior.

When `worktrees/<slug>/web` exists, the vpsFree.cz web is served from a live
symlink tree backed by that worktree. Its generated `config.php` points to the
devcluster API.

Ruby services and system-level changes use:

```sh
vpsadmin-devcluster update <slug> services
vpsadmin-devcluster update <slug> node1
```

which rebuilds the machine config, copies the new closure to the running VM,
and runs `switch-to-configuration`.

When changing Ruby code packaged as gems, rebuild vpsAdmin packaged gems before
updating the cluster:

```sh
cd worktrees/<slug>/vpsadmin
nix develop -c rake vpsadmin:gems
```

`start` and `update` stop if credential or source preparation fails. A failure
before Nix publishes `result-config` leaves the previous result selected, or
no result on a first build. Nix can fail after publishing a complete new
result, for example while registering its GC root. In that case, status
describes the selected build; it does not show whether the services VM
activated it. Record the selected output path and failure phase, then retry
the normal build to establish rooting and validation before updating a VM.
Keep the compatible API and database schema, WebUI credentials, and BFF
session state. Do not reset the cluster or rotate secrets to recover from this
failure. An update stops at the first failed copy, activation, or refresh.
Machines updated before that failure keep their new configuration.
