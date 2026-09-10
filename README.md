# vpsFree.cz development workspace extensions

This repository adds vpsFree.cz tools to the reusable
[`aither64/dev-workspace`](https://github.com/aither64/dev-workspace) runtime.
It owns the KB commands, vpsAdmin and vpsAdminOS development-cluster providers,
and Codex skills.

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

Run all checks with:

```sh
nix flake check --print-build-logs
```
