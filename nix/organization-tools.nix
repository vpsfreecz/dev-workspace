{
  bash,
  coreutils,
  diffutils,
  gawk,
  git,
  gnugrep,
  gnused,
  iproute2,
  jq,
  lib,
  makeWrapper,
  nix,
  openssh,
  openssl,
  ruby,
  runtimeContract,
  siteConfig,
  src,
  stdenvNoCC,
  systemd,
  tmux,
  util-linux,
}:
let
  kb = siteConfig.kb or { };
  clusters = siteConfig.clusterDefaults or { };
  clusterConfigurations = builtins.mapAttrs (
    name: value:
    builtins.path {
      path = value;
      name = "dev-workspace-${name}-cluster.json";
    }
  ) clusters;
  requiredStrings = {
    czUrl = kb.cz.url;
    czTokenPath = kb.cz.tokenPath;
    czStagingUrl = kb.cz.stagingUrl;
    czStagingPasswordPath = kb.cz.stagingPasswordPath;
    orgUrl = kb.org.url;
    orgTokenPath = kb.org.tokenPath;
    orgStagingUrl = kb.org.stagingUrl;
    orgStagingPasswordPath = kb.org.stagingPasswordPath;
    stagingUsername = kb.stagingUsername;
    stageContainerctl = kb.stageContainerctl;
  };
  kbRuntimePath = lib.makeBinPath [
    coreutils
    git
    openssl
  ];
  migrationRuntimePath = lib.makeBinPath [
    coreutils
    systemd
    tmux
  ];
  clusterRuntimePath = lib.makeBinPath [
    bash
    coreutils
    gawk
    git
    gnugrep
    gnused
    iproute2
    jq
    nix
    openssh
    openssl
    util-linux
  ];
  runtimeContractData = builtins.fromJSON (builtins.readFile runtimeContract);
  authorityPolicyValid = (runtimeContractData.runtimeAuthorityIdentityPolicy or null) == 1;
in
assert lib.assertMsg authorityPolicyValid
  "the namespace migration must be reviewed for the selected runtime authority policy";
stdenvNoCC.mkDerivation {
  pname = "vpsfree-dev-workspace-tools";
  version = "0.1.0";

  inherit src;
  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/share/vpsfree-dev-workspace"
    cp -R bin lib dev-clusters "$out/share/vpsfree-dev-workspace/"
    install -Dm644 nix/host-paths.json \
      "$out/share/vpsfree-dev-workspace/nix/host-paths.json"
    chmod -R u+w "$out/share/vpsfree-dev-workspace"
    for provider in vpsadmin vpsadminos; do
      install -Dm644 dev-clusters/lib/devcluster_runner.rb \
        "$out/share/vpsfree-dev-workspace/dev-clusters/$provider/shared/devcluster_runner.rb"
    done
    install -m644 ${clusterConfigurations.vpsadmin} \
      "$out/share/vpsfree-dev-workspace/dev-clusters/vpsadmin/default-config.json"
    install -m644 ${clusterConfigurations.vpsadminos} \
      "$out/share/vpsfree-dev-workspace/dev-clusters/vpsadminos/default-config.json"
    install -Dm644 ${runtimeContract} \
      "$out/share/vpsfree-dev-workspace/dev-clusters/runtime-contract.json"
    for source in "$out/share/vpsfree-dev-workspace/bin/"*; do
      substituteInPlace "$source" \
        --replace-fail '#!/usr/bin/env ruby' '#!${ruby}/bin/ruby'
      name=$(basename "$source")
      runtimePath=${lib.escapeShellArg kbRuntimePath}
      if [ "$name" = vpsfree-dev-workspace-migrate ]; then
        runtimePath=${lib.escapeShellArg migrationRuntimePath}
      fi
      makeWrapper "$source" "$out/bin/$name" \
        --prefix RUBYLIB : "$out/share/vpsfree-dev-workspace/lib" \
        --prefix PATH : "$runtimePath" \
        --set DEV_WORKSPACE_RUNTIME_CONTRACT \
          "$out/share/vpsfree-dev-workspace/dev-clusters/runtime-contract.json" \
        --set VPSFREE_KB_CZ_URL ${lib.escapeShellArg requiredStrings.czUrl} \
        --set VPSFREE_KB_CZ_TOKEN_PATH ${lib.escapeShellArg requiredStrings.czTokenPath} \
        --set VPSFREE_KB_CZ_STAGING_URL ${lib.escapeShellArg requiredStrings.czStagingUrl} \
        --set VPSFREE_KB_CZ_STAGING_PASSWORD_PATH ${lib.escapeShellArg requiredStrings.czStagingPasswordPath} \
        --set VPSFREE_KB_ORG_URL ${lib.escapeShellArg requiredStrings.orgUrl} \
        --set VPSFREE_KB_ORG_TOKEN_PATH ${lib.escapeShellArg requiredStrings.orgTokenPath} \
        --set VPSFREE_KB_ORG_STAGING_URL ${lib.escapeShellArg requiredStrings.orgStagingUrl} \
        --set VPSFREE_KB_ORG_STAGING_PASSWORD_PATH ${lib.escapeShellArg requiredStrings.orgStagingPasswordPath} \
        --set VPSFREE_KB_STAGING_USERNAME ${lib.escapeShellArg requiredStrings.stagingUsername} \
        --set KB_STAGE_CONTAINERCTL ${lib.escapeShellArg requiredStrings.stageContainerctl}
    done

    substituteInPlace \
      "$out/share/vpsfree-dev-workspace/dev-clusters/vpsadmin/bin/devcluster" \
      "$out/share/vpsfree-dev-workspace/dev-clusters/vpsadminos/bin/devcluster" \
      --replace-fail '#!/usr/bin/env bash' '#!${bash}/bin/bash'

    makeWrapper \
      "$out/share/vpsfree-dev-workspace/dev-clusters/vpsadmin/bin/devcluster" \
      "$out/bin/vpsadmin-devcluster" \
      --prefix PATH : ${lib.escapeShellArg clusterRuntimePath} \
      --set VPSADMIN_DEVCLUSTER_DEFAULT_CONFIG ${lib.escapeShellArg (toString clusterConfigurations.vpsadmin)}
    makeWrapper \
      "$out/share/vpsfree-dev-workspace/dev-clusters/vpsadminos/bin/devcluster" \
      "$out/bin/vpsadminos-devcluster" \
      --prefix PATH : ${lib.escapeShellArg clusterRuntimePath} \
      --set VPSADMINOS_DEVCLUSTER_DEFAULT_CONFIG ${lib.escapeShellArg (toString clusterConfigurations.vpsadminos)}

    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    mkdir -p "$TMPDIR/workspace"
    for provider in vpsadmin vpsadminos; do
      cluster="$out/share/vpsfree-dev-workspace/dev-clusters/$provider"
      test -f "$cluster/default-config.json"
      test ! -L "$cluster/default-config.json"
      test -f "$cluster/shared/devcluster_runner.rb"
      test ! -L "$cluster/shared/devcluster_runner.rb"
      ${diffutils}/bin/cmp dev-clusters/lib/devcluster_runner.rb "$cluster/shared/devcluster_runner.rb"
    done
    ${diffutils}/bin/cmp ${clusterConfigurations.vpsadmin} \
      "$out/share/vpsfree-dev-workspace/dev-clusters/vpsadmin/default-config.json"
    ${diffutils}/bin/cmp ${clusterConfigurations.vpsadminos} \
      "$out/share/vpsfree-dev-workspace/dev-clusters/vpsadminos/default-config.json"
    ${jq}/bin/jq -e 'type == "object"' \
      ${lib.escapeShellArg (toString clusterConfigurations.vpsadmin)} >/dev/null
    ${jq}/bin/jq -e 'type == "object"' \
      ${lib.escapeShellArg (toString clusterConfigurations.vpsadminos)} >/dev/null
    for command in "$out/bin/"kb-*; do
      status=0
      "$command" --help >"$TMPDIR/help" 2>&1 || status=$?
      case "$(basename "$command")" in
        kb-release|kb-stage) test "$status" -eq 1 ;;
        *) test "$status" -eq 0 ;;
      esac
      grep -q '^Usage:' "$TMPDIR/help"
    done
    DEVCLUSTER_WORKSPACE="$TMPDIR/workspace" "$out/bin/vpsadmin-devcluster" --help >/dev/null
    DEVCLUSTER_WORKSPACE="$TMPDIR/workspace" "$out/bin/vpsadminos-devcluster" --help >/dev/null
    ${coreutils}/bin/env -i HOME="$TMPDIR" PATH=/empty \
      "$out/bin/vpsfree-dev-workspace-migrate" --help >/dev/null
  '';
}
