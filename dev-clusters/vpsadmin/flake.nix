{
  description = "Workspace-local vpsAdmin development clusters";

  inputs = {
    vpsadmin.url = "github:vpsfreecz/vpsadmin/5c76e3290481b297dcd0baa76d246133f0353d8f";
    vpsadminos.url = "github:vpsfreecz/vpsadminos/staging";
    vpsadminWebui = {
      url = "github:vpsfreecz/vpsadmin-webui/534caa83a5f97d2b40b4a126886649b14dc9e8d3";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.vpsadmin.follows = "vpsadmin";
    };
    vpsfStatus = {
      url = "github:vpsfreecz/vpsf-status/master";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.vpsadmin.follows = "vpsadmin";
      inputs.vpsadminos.follows = "vpsadminos";
    };
    nixpkgs.follows = "vpsadminos/nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      vpsadmin,
      vpsadminos,
      vpsadminWebui,
      vpsfStatus,
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

      workspace = env "VPSADMIN_DEVCLUSTER_WORKSPACE" (env "PWD" ".");
      slug = env "VPSADMIN_DEVCLUSTER_SLUG" "dev";
      topology = env "VPSADMIN_DEVCLUSTER_TOPOLOGY" "single";
      networkMode = env "VPSADMIN_DEVCLUSTER_NETWORK" "bridge";
      bridgeHelper = env "VPSADMIN_DEVCLUSTER_BRIDGE_HELPER" "/run/wrappers/bin/qemu-bridge-helper";
      certDir = env "VPSADMIN_DEVCLUSTER_CERT_DIR" "${workspace}/.dev-clusters/vpsadmin/certs/default";
      clusterConfigFile = env "VPSADMIN_DEVCLUSTER_CONFIG_FILE" "";
      sshPubKey = env "VPSADMIN_DEVCLUSTER_SSH_PUBKEY" "${workspace}/.dev-clusters/vpsadmin/ssh/id_ed25519.pub";
      vpsadminSourcePath = env "VPSADMIN_DEVCLUSTER_VPSADMIN_SOURCE" vpsadmin.outPath;
      vpsadminosSourcePath = env "VPSADMIN_DEVCLUSTER_VPSADMINOS_SOURCE" vpsadminos.outPath;
      vpsadminRevision = env "VPSADMIN_DEVCLUSTER_VPSADMIN_REVISION" (vpsadmin.rev or "");
      vpsadminRevisionDirty = env "VPSADMIN_DEVCLUSTER_VPSADMIN_DIRTY" "0" == "1";
      vpsadminosRevision = env "VPSADMIN_DEVCLUSTER_VPSADMINOS_REVISION" (vpsadminos.rev or "");
      vpsadminosRevisionDirty = env "VPSADMIN_DEVCLUSTER_VPSADMINOS_DIRTY" "0" == "1";
      vpsadminWebuiRevision = env "VPSADMIN_DEVCLUSTER_VPSADMIN_WEBUI_REVISION" (vpsadminWebui.rev or "");
      vpsadminWebuiRevisionDirty = env "VPSADMIN_DEVCLUSTER_VPSADMIN_WEBUI_DIRTY" "0";
      vpsadminWebuiSourceKind = env "VPSADMIN_DEVCLUSTER_VPSADMIN_WEBUI_SOURCE_KIND" "pinned";
      webuiCredentialsDir = env "VPSADMIN_DEVCLUSTER_WEBUI_CREDENTIALS_DIR" "";
      haveapiSourcePath = env "VPSADMIN_DEVCLUSTER_HAVEAPI_SOURCE" "";
      configSourcePath = env "VPSADMIN_DEVCLUSTER_CONFIG_SOURCE" "";
      mailTemplatesSourcePath = env "VPSADMIN_DEVCLUSTER_MAIL_TEMPLATES_SOURCE" "";
      webSourcePath = env "VPSADMIN_DEVCLUSTER_WEB_SOURCE" "";
      vpsfStatusSourcePath = env "VPSADMIN_DEVCLUSTER_VPSF_STATUS_SOURCE" "";
      vpsadminGoClientSourcePath = env "VPSADMIN_DEVCLUSTER_VPSADMIN_GO_CLIENT_SOURCE" "";
      sharedRunnerLib = builtins.path {
        path = ./shared;
        name = "devcluster-runner-lib";
      };

      # Build selection stays current; these fields describe the booted host.
      projectUpdateConfig =
        applied: target: requested:
        let
          payloadFields =
            machine:
            if (machine.bootMode or "direct") != "direct" then
              [ ]
            else if machine.spin == "nixos" then
              [
                "toplevel"
                "kernel"
                "initrd"
              ]
            else if machine.spin == "vpsadminos" then
              [
                "toplevel"
                "kernel"
                "initrd"
                "squashfs"
              ]
            else
              [ ];
          layout =
            machine:
            let
              rest = builtins.removeAttrs machine (payloadFields machine);
            in
            rest
            //
              lib.optionalAttrs
                (machine.spin == "nixos" && (machine.bootMode or "direct") == "direct" && machine ? rootDisk)
                {
                  rootDisk = builtins.removeAttrs machine.rootDisk [ "image" ];
                };
          bootHost =
            name: machine:
            let
              old = applied.machines.${name};
            in
            if !(machine ? qemu && machine ? virtiofsd && machine.sharedFileSystems ? vpsadminos) then
              throw "The requested configuration changes the retained VM topology or layout."
            else
              machine
              // {
                inherit (old) qemu virtiofsd;
                sharedFileSystems = machine.sharedFileSystems // {
                  inherit (old.sharedFileSystems) vpsadminos;
                };
              };
          requestedMachines = lib.mapAttrs bootHost requested.machines;
          selected = name: target == "all" || target == name;
          valid =
            builtins.attrNames requested.machines == builtins.attrNames applied.machines
            && (target == "all" || target == "boot" || builtins.hasAttr target applied.machines)
            &&
              builtins.removeAttrs requested [
                "machines"
                "labels"
              ] == builtins.removeAttrs applied [
                "machines"
                "labels"
              ]
            && lib.all (name: layout requestedMachines.${name} == layout applied.machines.${name}) (
              builtins.attrNames applied.machines
            );
        in
        if !valid then
          throw "The requested configuration changes the retained VM topology or layout."
        else
          requested
          // {
            machines = lib.mapAttrs (
              name: machine:
              if !selected name then
                applied.machines.${name}
              else
                machine
                //
                  lib.optionalAttrs
                    (machine.spin == "nixos" && (machine.bootMode or "direct") == "direct" && machine ? rootDisk)
                    {
                      rootDisk =
                        builtins.removeAttrs machine.rootDisk [ "image" ]
                        // lib.optionalAttrs (applied.machines.${name}.rootDisk ? image) {
                          inherit (applied.machines.${name}.rootDisk) image;
                        };
                    }
            ) requestedMachines;
          };
      appliedConfigFile = env "VPSADMIN_DEVCLUSTER_APPLIED_CONFIG" "";
      updateTarget = env "VPSADMIN_DEVCLUSTER_UPDATE_TARGET" "";
      selectedConfig =
        if appliedConfigFile == "" then
          clusterConfig.json
        else
          nixpkgs.legacyPackages.${system}.writeText "vpsadmin-devcluster-${slug}-${updateTarget}.json" (
            builtins.toJSON (
              projectUpdateConfig (builtins.fromJSON (
                builtins.readFile appliedConfigFile
              )) updateTarget clusterConfig.config
            )
          );

      clusterTest = import ./nix/test.nix {
        inherit
          lib
          vpsadmin
          vpsadminos
          vpsadminWebui
          vpsfStatus
          workspace
          slug
          topology
          networkMode
          bridgeHelper
          certDir
          clusterConfigFile
          sshPubKey
          vpsadminSourcePath
          vpsadminosSourcePath
          vpsadminRevision
          vpsadminRevisionDirty
          vpsadminosRevision
          vpsadminosRevisionDirty
          vpsadminWebuiRevision
          vpsadminWebuiRevisionDirty
          vpsadminWebuiSourceKind
          webuiCredentialsDir
          haveapiSourcePath
          configSourcePath
          mailTemplatesSourcePath
          webSourcePath
          vpsfStatusSourcePath
          vpsadminGoClientSourcePath
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
        name = "vpsadmin-devcluster-runner";
        runnerLib = ./lib;
      };
    in
    {
      lib.projectUpdateConfig = projectUpdateConfig;
      lib.webuiPackageProvenance = {
        frontend = vpsadminWebui.packages.${system}.frontend.provenance.buildInfo;
        bff = vpsadminWebui.packages.${system}.bff.provenance.buildInfo;
      };

      packages.${system} = {
        cluster-config = selectedConfig;
        inherit runner;
        default = selectedConfig;
      };

      apps.${system} = {
        runner = {
          type = "app";
          program = "${runner}/bin/vpsadmin-devcluster-runner";
        };
        default = self.apps.${system}.runner;
      };
    };
}
