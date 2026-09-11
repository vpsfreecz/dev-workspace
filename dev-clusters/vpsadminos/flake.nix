{
  description = "Workspace-local vpsAdminOS development clusters";

  inputs = {
    vpsadminos.url = "github:vpsfreecz/vpsadminos/staging";
    nixpkgs.follows = "vpsadminos/nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      vpsadminos,
    }:
    let
      system = "x86_64-linux";
      lib = nixpkgs.lib;

      env =
        name: default:
        let
          value = builtins.getEnv name;
        in
        if value == "" then default else value;

      workspace = env "VPSADMINOS_DEVCLUSTER_WORKSPACE" (env "PWD" ".");
      slug = env "VPSADMINOS_DEVCLUSTER_SLUG" "dev";
      topology = env "VPSADMINOS_DEVCLUSTER_TOPOLOGY" "single";
      networkMode = env "VPSADMINOS_DEVCLUSTER_NETWORK" "local";
      bridgeHelper = env "VPSADMINOS_DEVCLUSTER_BRIDGE_HELPER" "/run/wrappers/bin/qemu-bridge-helper";
      clusterConfigFile = env "VPSADMINOS_DEVCLUSTER_CONFIG_FILE" "";
      sshPubKey = env "VPSADMINOS_DEVCLUSTER_SSH_PUBKEY" "${workspace}/.dev-clusters/vpsadminos/ssh/id_ed25519.pub";
      vpsadminosSourcePath = env "VPSADMINOS_DEVCLUSTER_VPSADMINOS_SOURCE" vpsadminos.outPath;
      sharedRunnerLib = builtins.path {
        path = ./shared;
        name = "devcluster-runner-lib";
      };

      clusterTest = import ./nix/test.nix {
        inherit
          lib
          vpsadminos
          workspace
          slug
          topology
          networkMode
          bridgeHelper
          clusterConfigFile
          sshPubKey
          vpsadminosSourcePath
          ;
      };

      # Validate the runner source interface before a configuration build.
      clusterConfig = builtins.seq runner (
        import (vpsadminos.outPath + "/tests/make-test.nix") clusterTest {
          inherit system;
          pkgs = nixpkgs.outPath;
          extraArgs = {
            inherit vpsadminos;
          };
        }
      );

      runner = import ./shared/runner.nix {
        inherit
          nixpkgs
          vpsadminos
          system
          sharedRunnerLib
          ;
        name = "vpsadminos-devcluster-runner";
        runnerLib = ./lib;
      };
    in
    {
      packages.${system} = {
        cluster-config = clusterConfig.json;
        inherit runner;
        default = clusterConfig.json;
      };

      apps.${system} = {
        runner = {
          type = "app";
          program = "${runner}/bin/vpsadminos-devcluster-runner";
        };
        default = self.apps.${system}.runner;
      };
    };
}
