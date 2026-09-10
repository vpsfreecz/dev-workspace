{
  description = "vpsFree.cz extensions for reusable development workspaces";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    dev-workspace.url = "github:aither64/dev-workspace/086e3d867140ab090e507a194b7fdfc1cc43cc65";
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      dev-workspace,
      ...
    }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      skillNames = builtins.attrNames (
        nixpkgs.lib.filterAttrs (
          name: type: type == "directory" && builtins.pathExists "${self}/skills/${name}/SKILL.md"
        ) (builtins.readDir ./skills)
      );
      commandNames = [
        "kb-cleanup"
        "kb-contract-build"
        "kb-contract-fetch"
        "kb-contract-manifest"
        "kb-contract-reconcile"
        "kb-page"
        "kb-release"
        "kb-stage"
      ];
      mkOrganizationTools =
        {
          pkgs,
          siteConfig,
        }:
        pkgs.callPackage ./nix/organization-tools.nix {
          src = self;
          runtimeContract = dev-workspace.lib.runtimeContract;
          inherit siteConfig;
        };
      mkPackage =
        {
          pkgs,
          siteConfig,
        }:
        let
          tools = mkOrganizationTools { inherit pkgs siteConfig; };
        in
        dev-workspace.lib.mkPackage {
          inherit
            pkgs
            ;
          extensions = {
            commands = builtins.listToAttrs (
              map (name: {
                inherit name;
                value = "${tools}/bin/${name}";
              }) commandNames
            );
            skills = builtins.listToAttrs (
              map (name: {
                inherit name;
                value = "${self}/skills/${name}";
              }) skillNames
            );
            clusterProviders = {
              vpsadmin = {
                label = "vpsAdmin";
                command = "${tools}/bin/vpsadmin-devcluster";
              };
              vpsadminos = {
                label = "vpsAdminOS";
                command = "${tools}/bin/vpsadminos-devcluster";
              };
            };
          };
        };
      testSiteConfig = {
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
          vpsadmin = ./test/fixtures/vpsadmin-config.json;
          vpsadminos = ./test/fixtures/vpsadminos-config.json;
        };
      };
      testPackage = mkPackage {
        inherit pkgs;
        siteConfig = testSiteConfig;
      };
      rejectedClusterDefaults = [ "/tmp/mutable-vpsadmin.json" ];
      invalidClusterDefaultsRejected = builtins.all (
        value:
        !(builtins.tryEval (
          builtins.deepSeq (mkOrganizationTools {
            inherit pkgs;
            siteConfig = testSiteConfig // {
              clusterDefaults = testSiteConfig.clusterDefaults // {
                vpsadmin = value;
              };
            };
          }) true
        )).success
      ) rejectedClusterDefaults;
      testEnvironment = ''
        export LANG=C.UTF-8
        export LC_ALL=C.UTF-8
        export VPSFREE_KB_CZ_URL=https://kb-cz.example.test
        export VPSFREE_KB_CZ_TOKEN_PATH=/credentials/kb-cz-token
        export VPSFREE_KB_CZ_STAGING_URL=https://kb-cz-staging.example.test
        export VPSFREE_KB_CZ_STAGING_PASSWORD_PATH=/credentials/kb-cz-staging-password
        export VPSFREE_KB_ORG_URL=https://kb-org.example.test
        export VPSFREE_KB_ORG_TOKEN_PATH=/credentials/kb-org-token
        export VPSFREE_KB_ORG_STAGING_URL=https://kb-org-staging.example.test
        export VPSFREE_KB_ORG_STAGING_PASSWORD_PATH=/credentials/kb-org-staging-password
        export VPSFREE_KB_STAGING_USERNAME=developer
        export KB_STAGE_CONTAINERCTL=/run/current-system/sw/bin/containerctl
        export VPSADMIN_DEVCLUSTER_DEFAULT_CONFIG=$PWD/test/fixtures/vpsadmin-config.json
        export VPSADMINOS_DEVCLUSTER_DEFAULT_CONFIG=$PWD/test/fixtures/vpsadminos-config.json
        export DEVCLUSTER_RUNTIME_CONTRACT=${dev-workspace.lib.runtimeContract}
      '';
    in
    assert invalidClusterDefaultsRejected;
    {
      lib = {
        inherit mkPackage;
      };
      checks.${system} = {
        package = testPackage;
        tests =
          pkgs.runCommand "vpsfree-dev-workspace-tests"
            {
              nativeBuildInputs = [
                pkgs.bash
                pkgs.coreutils
                pkgs.git
                pkgs.jq
                pkgs.openssl
                pkgs.ruby
                pkgs.tmux
                pkgs.util-linux
              ];
            }
            ''
              cp -R ${self} source
              chmod -R u+w source
              cd source
              patchShebangs bin dev-clusters
              ${testEnvironment}
              ruby test/devcluster_status_test.rb
              ruby test/kb_cleanup_test.rb
              ruby test/kb_contract_tools_test.rb
              ruby test/kb_page_test.rb
              ruby test/kb_stage_test.rb
              ruby test/migration_test.rb
              touch "$out"
            '';
        organization-source = pkgs.runCommand "vpsfree-dev-workspace-source" { } ''
          first=aither
          if grep -RilE "$first"'dev' ${self} --exclude-dir=.git > matches; then
            cat matches >&2
            exit 1
          fi
          if ${pkgs.findutils}/bin/find ${self} -printf '%P\n' | grep -iE "$first"'dev' > matches; then
            cat matches >&2
            exit 1
          fi
          touch "$out"
        '';
      };
    };
}
