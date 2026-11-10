# vpsAdminOS Dev Clusters

The selected vpsAdminOS source must provide OSVM's per-disk `preserve` setting
and `overlays.all`. The runner checks the disk API before constructing any VM.
Writable disks are preserved by default; the squashfs boot image and temporary
root filesystem keep their usual boot behavior. Update older selected OS sources
before starting the cluster.


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

The workspace portal offers Start/Stop and Release beside cluster readiness.
Its Start action runs `vpsadminos-devcluster start <slug> --existing`: it requires
retained state and configuration, reuses the saved topology/network and follows
normal build/boot behavior from the session's selected sources. This option
accepts no other arguments. Stop preserves disks and configuration; Release
stops the cluster and deletes them after confirmation. Initial setup remains a
CLI operation. Source compatibility requirements still apply to retained disks.

The provider advertises its available actions through the generic runtime's
[provider contract](https://github.com/aither64/dev-workspace/blob/master/docs/workspace-portal.md#cluster-provider-status-and-shutdown-contract).
It emits this metadata only for `DEVCLUSTER_PORTAL_CONTROLS=1`, keeping ordinary
status JSON compatible with older readers. The same environment requests
nonblocking mutation locking. No disk or cluster-state conversion is required.

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

### Optional image repository demo

The optional addon uses `osctl-repo-server` from the selected vpsAdminOS package.
That source must export `packages.<system>.osctl-repo-server`. Omit
`imageRepository`, or set `enable` to `false`, to keep the normal cluster unchanged.

```json
{
  "imageRepository": {
    "enable": true,
    "node": "node1",
    "port": 8080,
    "seed": true,
    "limits": {
      "maxBytes": 67108864,
      "reserveBytes": 16777216,
      "maxUploadBytes": 8388608,
      "maxRuns": 8,
      "leaseSeconds": 86400
    }
  }
}
```

The node must belong to the selected topology. The native runit service
`osctl-repo-server-demo` listens on `127.0.0.1:8080` in that guest. It does not
change container repositories or open a network port. The consuming site owns
any TLS proxy and explicit SSH forwarding. The requester header is
`X-Repo-Client-IP`, trusted only from `127.0.0.1/32`; a proxy must overwrite it.
Local callers can supply this header, so it is diagnostic data, not identity.

The dedicated `tank/osctl-repo-server-demo` dataset mounts at
`/var/lib/osctl-repo-server-demo`. State and logs are private to `osctl-repo-demo`;
role sockets are under `/run/osctl-repo-server-demo`, with separate
`repo-demo-producer`, `repo-demo-publisher` and `repo-demo-admin` groups.
The dataset property `com.vpsfree:repo-demo=1` and `DEMO` marker identify it.
An existing unmarked dataset or conflicting mountpoint fails explicitly.
Restarts and ordinary updates retain data. Nothing is seeded or erased on boot.

Optional `displayName` and `purpose` set the repository name and description
shown by the server. The addon accepts up to 128 and 512 bytes respectively,
without control characters. Empty values display the repository ID and omit the
description. `instance`, `statsDays` and `statsMaxRows` default to
`synthetic-demo`, 7 and 256. The instance must be a safe path component; retention
accepts 1 to 365 days and the row cap accepts 1 to 65,536. Changing the instance
does not move or erase old measurements. Payload, log and run limits are separate.

A representative test preview can explicitly select:

```json
{
  "imageRepository": {
    "enable": true,
    "displayName": "Synthetic image catalog preview",
    "purpose": "Synthetic files and simulated usage; new measurements come from preview traffic, not production downloads.",
    "instance": "synthetic-history-v1",
    "statsDays": 365,
    "statsMaxRows": 65536
  }
}
```

The page shows this purpose above the statistics and catalog. Distribution names
come from a frozen public metadata snapshot; the tiny archives are **not operating systems**,
and the ZFS placeholders are **not valid streams**. Simulated large transfer
values describe a historical fixture, never the actual tiny file sizes or
production usage. Source provenance and complete-union preparation are documented
in [the fixture guide](fixtures/image-repository/README.md).

Run these preparation and maintenance commands explicitly. They require a marked
existing demo and a coherent backup. Stop the service and maintenance before
changing data.

```sh
osctl-repo-demo-fixtures /absolute/new-synthetic-catalog
osctl-repo-demo-prepare-catalog /absolute/coherent-export /absolute/new-union EXPECTED_GENERATION --accept-default-transition
osctl-repo-demo-history generate /absolute/new-history.json RECORDED_REAL_UTC_SEED_TIME
# Only with the service, statistics writer and maintenance stopped:
osctl-repo-demo-history apply /absolute/new-history.json
```

The catalog command prepares a complete portable union and CAS request without
submitting it. The union preserves current tuples, file IDs and bytes. Import
preserves runs, receipts and history. The `default` alias changes to
`vpsadminos/minimal` only when explicitly accepted; existing `demo/minimal`
canonical and nonconflicting tag paths remain. Validate the output and apply its
stable `import-request.json` through the existing admin ctl, after review and
backup. Never import the raw 178-entry catalog as a replacement or run the old
seed to enrich current data. Concurrent public generation changes or collisions
require reconciliation before import; do not force a replacement or reset the dataset.

The addon-only history helper uses its packaged SQLite CLI and refuses any schema
other than exactly 2, an unmarked root, another repository/instance, or an active
writer. It inserts at most 50,000 typed daily rows and one metadata row for
`synthetic-history-v1` in a single exclusive transaction. Original
`synthetic-demo` data remains unchanged. Dates are explicit in the preceding
365-day window at a fixed real UTC seed time; quiet dates, full/range responses,
interruptions and errors are deliberately simulated. It writes no access events.

Keep the private `synthetic-history-v1.json` manifest in backups. A prepared
manifest reconciles a commit-before-marker interruption only if every row and
metadata value matches exactly. An applied manifest returns already-applied and
never overwrites subsequent preview observations or pruned history. Unknown
content or a lost marker with changed data refuses. Restore a coherent matching
schema-2 dataset/manifest/config with writers stopped; deleting some counter rows
or replaying against stale WAL is not rollback. Preserve older backups for their
original version boundary. No automatic dataset reset or cleanup is provided.

Run the installed command explicitly as guest root:

```sh
vpsadminos-devcluster ssh <slug> node1 -- osctl-repo-demo-seed
```

Setting `seed` to `false` omits this command. The seed command imports two tiny
deterministic tar archives labelled as synthetic data and creates sealed, pending and failed
demo runs through the existing control protocol. No OS build or test takes place;
the fixture's verified state only exercises the protocol. The command emits run
keys and expected SHA256 hashes and saves them in `seed.json` beside the marker.
Identical retries reuse stable request IDs and preserve existing payloads. Changed
fixture files fail rather than being replaced. The command has a three-minute
deadline and generates eight local HTTP requests once, including HEAD, Range and
error responses. An interrupted traffic batch can repeat that bounded batch.
It makes no external downloads or direct database writes.

Limits are fixture capacity, not production sizing: at most 64 MiB payload,
8 MiB per upload, three to eight runs, and leases from one hour to one day.
Statistics retain seven days with at most 256 rows. Access logs retain two 1 MiB
files in total; service logs keep a current 1 MiB file and two rotated files.
Requester IP/UA remain in private
JSONL logs; public views contain aggregate counters only. Native guest cron runs
nonoverlapping, bounded `expire` then `reclaim` hourly through the admin socket.
Active leases and public references survive maintenance. Expired run fixtures
are not recreated by replaying old request IDs; inspect `seed.json` before use.
Refreshing expired data requires an explicitly authorized reset of this demo
dataset while the service is stopped. The addon supplies no reset command and
never resets the cluster or an unknown root.

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
