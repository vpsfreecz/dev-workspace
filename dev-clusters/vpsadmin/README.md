# vpsAdmin Dev Clusters

The installed `vpsadmin-devcluster` command runs vpsAdmin development clusters
from feature worktrees under `worktrees/<slug>/`. Run it from the registered
workspace or pass `--workspace NAME` before the command.

Runtime state, certificates, SSH keys, result links, and logs are stored under
`.dev-clusters/` at the workspace root and are intentionally not tracked by git.

The selected vpsAdminOS source must include commit `6f9b2c755` (June 12,
2026) or a compatible newer revision exposing `overlays.all` and
`vpsadminosRubyGemConfig`. Rebase older development worktrees before `start` or
`update`. Existing VM disks need no conversion.

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

`start` and `update` stop if credential preparation or configuration building
fails. They retain the previous build result for recovery and do not launch or
deploy it as a replacement for a failed build. An update stops at the first
failed copy, activation, or refresh; machines updated before that failure keep
their new configuration.
