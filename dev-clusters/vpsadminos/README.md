# vpsAdminOS Dev Clusters

The installed `vpsadminos-devcluster` command runs vpsAdminOS development
clusters. Run it from the registered workspace or pass `--workspace NAME` before
the command.
It boots vpsAdminOS VMs directly, without vpsAdmin services, database, web UI,
DNS services, mail capture, or seeded API data.

Runtime state, SSH keys, result links, VM disks, sockets, and logs are stored
under `.dev-clusters/vpsadminos/` at the workspace root and are intentionally
not tracked by git.

The selected vpsAdminOS source must include commit `6f9b2c755` (June 12,
2026) or a compatible newer revision exposing `overlays.all` and
`vpsadminosRubyGemConfig`. Rebase older development worktrees before `start` or
`update`. Existing VM disks need no conversion.

## Basic Usage

```sh
vpsadminos-devcluster start 2026-05-31-example
vpsadminos-devcluster info 2026-05-31-example
vpsadminos-devcluster ssh 2026-05-31-example node1
vpsadminos-devcluster update 2026-05-31-example node1
vpsadminos-devcluster stop 2026-05-31-example
vpsadminos-devcluster gcroots --cleanup
```

When running inside a `dev-session` shell, `ssh` can use
`DEV_SESSION_SLUG` automatically:

```sh
vpsadminos-devcluster ssh node1
vpsadminos-devcluster ssh node1 -- hostname
vpsadminos-devcluster ssh node1 -t -- bash -l
```

Topologies:

- `single`: one vpsAdminOS VM. This is the default.
- `dual`: two vpsAdminOS VMs.
- `triple`: three vpsAdminOS VMs.

Each VM boots with a persistent file-backed disk and an active `tank` pool, so
`osctl` can be used immediately after SSH login.

## Network Modes

`local` is the default. Each VM gets:

- `eth0`: QEMU user networking for internet access and SSH host forwarding;
- `eth1`: QEMU socket multicast networking for VM-to-VM traffic.

Local mode uses the configured `localNameservers` because QEMU's built-in
`10.0.2.3` resolver is not reliable in all vpsAdminOS test boots.

Default SSH forwards are:

- `node1`: `127.0.0.1:11122`
- `node2`: `127.0.0.1:11222`
- `node3`: `127.0.0.1:11322`

Example:

```sh
vpsadminos-devcluster start 2026-05-31-example --topology dual --network local
vpsadminos-devcluster ssh 2026-05-31-example node1
```

Some vpsAdminOS boots can spend several minutes without console output after
SeaBIOS. Use `--timeout seconds` when testing slower boots.

`bridge` attaches `eth1` to `br0`, assigns the configured `172.16.106.*`
addresses, and routes the VM through the bridge gateway. The current user needs
access to `/dev/kvm` and a usable QEMU bridge helper. The helper path defaults to
`/run/wrappers/bin/qemu-bridge-helper`; override it with:

```sh
VPSADMINOS_DEVCLUSTER_BRIDGE_HELPER=/path/to/helper \
  vpsadminos-devcluster start 2026-05-31-example --network bridge
```

Use an empty helper value to omit the QEMU `helper=` option.

## Configuration

Each cluster gets an editable config at:

```sh
.dev-clusters/vpsadminos/clusters/<slug>/config.json
```

The package receives its defaults from the consuming workspace through
`siteConfig.clusterDefaults.vpsadminos`. On first use, the helper copies them to
the cluster config. Nix merges this config over the packaged defaults, preserving
per-cluster overrides.
Use it to change node names, bridge/local IPs, SSH forward ports, memory, CPU,
disk sizes, topology membership, bridge name, gateway, local socket multicast
port, local resolvers, or upstream resolvers.

If `worktrees/<slug>/vpsadminos` exists, the cluster is built from that worktree.
Otherwise it is built from `repos/vpsadminos.git` `origin/staging`.

`start` and `update` keep the built cluster config rooted at
`.dev-clusters/vpsadminos/clusters/<slug>/result-config` while the cluster is in
use. `stop` removes that root after the runner exits, and `reset` removes it
with the rest of the cluster state. Use `vpsadminos-devcluster gcroots` to list retained
cluster config roots and `vpsadminos-devcluster gcroots --cleanup` to remove roots for
stopped clusters left by older tooling.

## Runtime Updates

After changing vpsAdminOS code or configuration, rebuild and switch a running VM:

```sh
vpsadminos-devcluster update <slug> node1
vpsadminos-devcluster update <slug> all
```

The update command copies the new system closure over SSH and runs
`switch-to-configuration switch` inside the selected VM.

Use `reset <slug>` to remove the per-slug VM state, including persistent disks.

`start` and `update` stop if credential preparation or configuration building
fails. They retain the previous build result for recovery and do not launch or
deploy it as a replacement for a failed build. An update stops at the first
failed copy or activation; machines updated before that failure keep
their new configuration.
