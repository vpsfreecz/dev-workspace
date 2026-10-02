{
  inputs,
  pkgs,
  organizationTools,
}:
let
  system = pkgs.stdenv.hostPlatform.system;
  vpsadmin = inputs.devcluster-vpsadmin;
  vpsadminos = inputs.devcluster-vpsadminos;
  lib = vpsadminos.inputs.nixpkgs.lib;
  provider = "${organizationTools}/share/vpsfree-dev-workspace/dev-clusters/vpsadmin";
  fixtureKeys =
    pkgs.runCommand "retained-services-fixture-keys"
      {
        nativeBuildInputs = [
          pkgs.openssh
          pkgs.openssl
        ];
      }
      ''
        mkdir "$out"
        ssh-keygen -q -t ed25519 -N "" -f "$out/id_ed25519"
        openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
          -subj /CN=retained-services.example.test \
          -keyout "$out/vpsadmin-cert.key" -out "$out/vpsadmin-cert.crt" \
          >/dev/null 2>&1
        cp "$out/vpsadmin-cert.crt" "$out/vpsadmin-ca.crt"
        cp "$out/vpsadmin-cert.key" "$out/vpsadmin-ca.key"
      '';
  configFile =
    enabled:
    pkgs.writeText "retained-services-${if enabled then "new" else "old"}.json" (
      builtins.toJSON {
        storageProfile = {
          enable = enabled;
          enrollment = true;
        };
        newWebui.enable = false;
      }
    );
  fixtureModule =
    variant:
    { lib, pkgs, ... }:
    let
      counter =
        name:
        pkgs.writeShellScript "retained-services-${variant}-${name}" ''
          mkdir -p /var/lib/storage-profile-fixture/counters
          printf 'start\n' >> /var/lib/storage-profile-fixture/counters/${variant}-${name}
          ${lib.optionalString (variant == "new" && name == "seed") ''
            touch /var/lib/storage-profile-fixture/new-seed-entered
            while test -e /var/lib/storage-profile-fixture/block-new-seed; do sleep 1; done
          ''}
        '';
      counted = {
        vpsadmin-devcluster-seed = "seed";
        vpsadmin-api = "api";
        vpsadmin-supervisor = "supervisor";
        vpsadmin-scheduler = "scheduler";
        vpsadmin-api-auth-tokens = "auth-tokens";
      };
    in
    {
      systemd.services = lib.mapAttrs (_: name: {
        serviceConfig.ExecStartPre = lib.mkAfter [ "+${counter name}" ];
      }) counted;
      systemd.timers.vpsadmin-api-auth-tokens.timerConfig = {
        OnCalendar = lib.mkForce "";
        OnBootSec = lib.mkForce "1s";
        OnUnitActiveSec = lib.mkForce "1s";
      };
    };
  test =
    enabled:
    { pkgs, ... }:
    let
      actual = import (provider + "/nix/test.nix") {
        inherit lib vpsadmin vpsadminos;
        vpsadminWebui = inputs.devcluster-vpsadminWebui;
        vpsfStatus = inputs.devcluster-vpsf-status;
        workspace = "/tmp/retained-services-fixture";
        slug = "retained-services-fixture";
        topology = "storage";
        networkMode = "local";
        bridgeHelper = "";
        certDir = fixtureKeys;
        clusterConfigFile = configFile enabled;
        sshPubKey = "${fixtureKeys}/id_ed25519.pub";
        vpsadminSourcePath = vpsadmin.outPath;
        vpsadminosSourcePath = vpsadminos.outPath;
        vpsadminRevision = vpsadmin.rev or "";
        vpsadminRevisionDirty = false;
        vpsadminosRevision = vpsadminos.rev or "";
        vpsadminosRevisionDirty = false;
        vpsadminWebuiRevision = "";
        vpsadminWebuiRevisionDirty = "0";
        vpsadminWebuiSourceKind = "pinned";
        webuiCredentialsDir = "";
        haveapiSourcePath = "";
        configSourcePath = "";
        mailTemplatesSourcePath = "";
        webSourcePath = "";
        vpsfStatusSourcePath = "";
        vpsadminGoClientSourcePath = "";
      } { inherit pkgs; };
    in
    actual
    // {
      # The real seed still sees the ordinary topology; only services boots.
      machines.services = actual.machines.services // {
        networks = [
          {
            type = "user";
            opts = {
              network = "10.0.2.0/24";
              host = "10.0.2.2";
              dns = "10.0.2.3";
              hostForward = "tcp:127.0.0.1:19122-:22";
            };
          }
        ];
        config = {
          imports = [
            actual.machines.services.config
            (fixtureModule (if enabled then "new" else "old"))
          ];
        };
      };
    };
  make =
    enabled:
    import (vpsadminos.outPath + "/tests/make-test.nix") (test enabled) {
      inherit system;
      pkgs = vpsadminos.inputs.nixpkgs.outPath;
      extraArgs = { inherit vpsadminos; };
    };
  resident = (make false).json;
  candidate = (make true).json;
  runner = import ../../dev-clusters/lib/runner.nix {
    inherit system vpsadminos;
    nixpkgs = vpsadminos.inputs.nixpkgs;
    name = "retained-services-maintenance-runner";
    runnerLib = ../../test/retained-services-maintenance;
    sharedRunnerLib = ../../dev-clusters/vpsadmin/lib;
  };
  # Carry the selected source inputs into invocation-time fixture evaluation.
  # The root flake keeps API/WebUI/status follows; OS's selected nixpkgs must
  # also survive the wrapper's separate Nix process.
  selectedSources = {
    nixpkgs = inputs.nixpkgs;
    dev-workspace = inputs.dev-workspace;
    devcluster-vpsadmin = vpsadmin;
    devcluster-vpsadminos = vpsadminos;
    "devcluster-vpsadminos/nixpkgs" = vpsadminos.inputs.nixpkgs;
    devcluster-vpsadminWebui = inputs.devcluster-vpsadminWebui;
    devcluster-vpsf-status = inputs.devcluster-vpsf-status;
  };
  sourceUrl =
    source:
    let
      # Preserve the resolved input's revision metadata along with its store
      # tree; OS package versioning can depend on these source attributes.
      parameters =
        lib.optional (source ? narHash) (
          "narHash=" + builtins.replaceStrings [ "+" "/" "=" ] [ "%2B" "%2F" "%3D" ] source.narHash
        )
        ++ lib.optional (source ? rev) "rev=${source.rev}"
        ++ lib.optional (source ? revCount) "revCount=${toString source.revCount}"
        ++ lib.optional (source ? lastModified) "lastModified=${toString source.lastModified}";
    in
    "path:${source.outPath}"
    + lib.optionalString (parameters != [ ]) ("?" + lib.concatStringsSep "&" parameters);
  sourceOverrides = lib.escapeShellArgs (
    lib.concatLists (
      lib.mapAttrsToList (name: source: [
        "--override-input"
        name
        (sourceUrl source)
      ]) selectedSources
    )
  );
in
{
  configs = { inherit resident candidate; };
  app = pkgs.writeShellApplication {
    name = "devcluster-maintenance-check";
    runtimeInputs = [
      pkgs.nix
      pkgs.openssh
      pkgs.coreutils
    ];
    text = ''
      if [ "$#" -gt 1 ]; then
        echo 'usage: devcluster-maintenance-check [NEW_EMPTY_ARTIFACT_DIR]' >&2
        exit 2
      fi
      if [ "$#" -eq 1 ]; then
        artifacts="$1"
        test ! -e "$artifacts" || { echo 'artifact directory must be new' >&2; exit 2; }
        mkdir -m 0700 -- "$artifacts"
      else
        artifacts="$(mktemp -d /tmp/retained-services.XXXXXXXX)"
      fi
      # Keep both Nix roots through exec, runner cleanup and failure inspection.
      # Use a separate directory so native artifacts are initially empty.
      roots="$(mktemp -d /tmp/retained-services-roots.XXXXXXXX)"
      chmod 0700 "$roots"
      echo "fixture Nix roots: $roots" >&2
      fixture_source=${lib.escapeShellArg (sourceUrl inputs.self)}
      selected_inputs=( ${sourceOverrides} )
      # Check compatibility before building either guest configuration. Default
      # app evaluation never forces the enabled candidate or its VM closure.
      nix eval --no-write-lock-file --raw "''${selected_inputs[@]}" \
        --apply 'config: config.drvPath' \
        "$fixture_source#lib.retainedServicesFixtureConfigs.candidate" >/dev/null
      resident=$(nix build --no-write-lock-file --out-link "$roots/resident" --print-out-paths \
        "''${selected_inputs[@]}" \
        "$fixture_source#lib.retainedServicesFixtureConfigs.resident")
      candidate=$(nix build --no-write-lock-file --out-link "$roots/candidate" --print-out-paths \
        "''${selected_inputs[@]}" \
        "$fixture_source#lib.retainedServicesFixtureConfigs.candidate")
      # Only these two built store outputs can reach the native sealed reader.
      for config in "$resident" "$candidate"; do
        case "$config" in
          /nix/store/*) test -f "$config" ;;
          *) echo 'fixture configuration is not a built store file' >&2; exit 1 ;;
        esac
      done
      export RETAINED_SERVICES_FIXTURE_SSH_KEY=${fixtureKeys}/id_ed25519
      exec ${runner}/bin/retained-services-maintenance-runner \
        --resident-config "$resident" --candidate-config "$candidate" \
        --artifact-dir "$artifacts"
    '';
  };
}
