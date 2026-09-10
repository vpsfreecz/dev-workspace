{
  description = "vpsFree.cz extensions for reusable development workspaces";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    dev-workspace.url = "github:aither64/dev-workspace/4b3d426d0484a62bac5bcfc7d5c7b6ff2140b045";
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
      migrationHostPaths = builtins.fromJSON (builtins.readFile ./nix/host-paths.json);
      hostPathContractMatches = migrationHostPaths == dev-workspace.lib.hostPaths;
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
          activationEnvironmentAliases ? [ ],
          pkgs,
          routerSocket ? dev-workspace.lib.hostPaths.routerSocket,
          siteConfig,
          userNamespace ? "dev-workspaces",
        }:
        let
          tools = mkOrganizationTools { inherit pkgs siteConfig; };
        in
        (dev-workspace.lib.mkPackage {
          inherit
            activationEnvironmentAliases
            pkgs
            routerSocket
            userNamespace
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
        }).overrideAttrs
          (previous: {
            postInstall = (previous.postInstall or "") + ''
              ln -s ${tools}/bin/vpsfree-dev-workspace-migrate \
                "$out/libexec/vpsfree-dev-workspace-migrate"
            '';
          });
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
      testCompatibilityPackage = mkPackage {
        activationEnvironmentAliases = [ "VPSFREE_WORKSPACE_ACTIVATION" ];
        inherit pkgs;
        routerSocket = "/run/previous-workspace-router/router.sock";
        siteConfig = testSiteConfig;
        userNamespace = "previous-workspaces";
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
        export DEV_WORKSPACE_RUNTIME_CONTRACT=${dev-workspace.lib.runtimeContract}
      '';
    in
    assert invalidClusterDefaultsRejected;
    assert hostPathContractMatches;
    {
      lib = {
        inherit mkPackage;
      };
      checks.${system} = {
        compatibility-package = testCompatibilityPackage;
        host-migration = import ./nix/tests/host-migration.nix {
          inherit pkgs;
          devWorkspace = dev-workspace;
          migrationPackage = testPackage;
        };
        package = testPackage;
        package-metadata = pkgs.runCommand "vpsfree-dev-workspace-package-metadata" { } ''
          ${pkgs.jq}/bin/jq -e \
            --arg router ${nixpkgs.lib.escapeShellArg dev-workspace.lib.hostPaths.routerSocket} \
            '.activationEnvironmentAliases == [] and
             .userNamespace == "dev-workspaces" and
             .routerSocket == $router' \
            ${testPackage}/share/dev-workspace/package.json >/dev/null
          ${pkgs.jq}/bin/jq -e \
            '.activationEnvironmentAliases == ["VPSFREE_WORKSPACE_ACTIVATION"] and
             .userNamespace == "previous-workspaces" and
             .routerSocket == "/run/previous-workspace-router/router.sock"' \
            ${testCompatibilityPackage}/share/dev-workspace/package.json >/dev/null
          ${pkgs.jq}/bin/jq -e \
            '[.commands[].name] == [
              "kb-cleanup",
              "kb-contract-build",
              "kb-contract-fetch",
              "kb-contract-manifest",
              "kb-contract-reconcile",
              "kb-page",
              "kb-release",
              "kb-stage"
            ]' \
          ${testPackage}/share/dev-workspace/extensions.json >/dev/null
          test ! -e ${testPackage}/bin/vpsfree-dev-workspace-migrate
          test -x ${testPackage}/libexec/vpsfree-dev-workspace-migrate
          touch "$out"
        '';
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
              export RUNTIME_AUTHORITY_CORPUS=${dev-workspace.lib.runtimeAuthorityCorpus}
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
