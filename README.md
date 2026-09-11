# vpsFree.cz development workspace extensions

This repository adds vpsFree.cz tools to the reusable
[`aither64/dev-workspace`](https://github.com/aither64/dev-workspace) runtime.
It owns the KB commands, vpsAdmin and vpsAdminOS development-cluster providers,
Codex skills, and the one-time namespace migration helper.

Concrete endpoints, credential paths, and development-cluster defaults are not
stored here. A consuming workspace passes them to `lib.mkPackage`:

```nix
vpsfree-dev-workspace.lib.mkPackage {
  inherit pkgs;
  siteConfig = {
    kb = {
      cz = {
        url = "https://kb-cz.example.test";
        tokenPath = "/credentials/kb-cz-token";
        stagingUrl = "https://kb-cz-staging.example.test";
        stagingPasswordPath = "/credentials/kb-cz-staging-password";
      };
      org = {
        url = "https://kb-org.example.test";
        tokenPath = "/credentials/kb-org-token";
        stagingUrl = "https://kb-org-staging.example.test";
        stagingPasswordPath = "/credentials/kb-org-staging-password";
      };
      stagingUsername = "developer";
      stageContainerctl = "/run/current-system/sw/bin/containerctl";
    };
    clusterDefaults = {
      vpsadmin = ./config/vpsadmin-devcluster.json;
      vpsadminos = ./config/vpsadminos-devcluster.json;
    };
  };
}
```

Each registered workspace keeps its portal identity and selected cluster
providers in the `.dev-workspace.json` file at its own root.

The optional `userNamespace` and `routerSocket` arguments are passed to the
generic package constructor. They are intended for a compatibility generation
during the namespace migration; ordinary packages should keep the generic
defaults.

Run the regular package and contract checks with:

```sh
nix flake check --print-build-logs
```

The migration helper is intentionally not automatic or linked into `~/bin`.
Invoke it through the package's private
`libexec/vpsfree-dev-workspace-migrate` path, read its `--help` output and
follow the [namespace migration runbook](docs/namespace-migration.md). Retain
its private journals until the deployed cutover has been accepted.

The local operator is trusted with host administration for workspace
integration and namespace migration. Root/user ownership supports their
operational lifecycle. Remote clients and guests remain untrusted, and KB
publication still requires its existing approval process.

The Host migration workflow runs the NixOS migration smoke test when migration
or local host-contract files change on `master`. After review, run the test
locally on feature branches or when an upstream host-state compatibility change
needs validation:

```sh
nix build --no-link --print-build-logs .#host-migration-test
```

Manual workflow dispatch is also available once the workflow exists on the
default branch. Regular dependency updates retain the fast Ruby migration and host-path
contract checks without booting this additional VM. CI requires KVM for the VM
job and targets normal dependency-update completion within 20 minutes.
