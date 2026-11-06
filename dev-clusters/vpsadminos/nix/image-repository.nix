{ vpsadminos, settings }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  root = "/var/lib/osctl-repo-server-demo";
  sockets = "/run/osctl-repo-server-demo";
  account = "osctl-repo-demo";
  limits = settings.limits;
  server = vpsadminos.packages.${pkgs.system}.osctl-repo-server;
  binary = "${server}/bin/osctl-repo-server";
  finite =
    name: maximum: builtins.isInt limits.${name} && limits.${name} > 0 && limits.${name} <= maximum;
  valid = builtins.all (x: x) [
    (finite "maxBytes" 67108864)
    (finite "reserveBytes" 67108864)
    (finite "maxUploadBytes" 8388608)
    (finite "maxRuns" 8)
    (finite "leaseSeconds" 86400)
    (limits.maxRuns >= 3)
    (limits.maxUploadBytes <= limits.maxBytes)
    (limits.leaseSeconds >= 3600)
    (builtins.isBool settings.seed)
  ];
  prepare = pkgs.writeShellScript "prepare-repository-demo" ''
    set -euo pipefail
    export PATH=${
      lib.makeBinPath [
        config.boot.zfsUserPackage
        pkgs.coreutils
        pkgs.util-linux
      ]
    }:${config.boot.zfsUserPackage}/sbin:$PATH
    exec 9>/run/osctl-repo-demo-prepare.lock
    flock 9
    dataset=tank/osctl-repo-server-demo
    if ! zfs list -H -o name "$dataset" >/dev/null 2>&1; then
      test ! -e ${root}
      zfs create -o mountpoint=${root} -o com.vpsfree:repo-demo=1 "$dataset"
    fi
    test "$(zfs get -H -o value com.vpsfree:repo-demo "$dataset")" = 1
    test "$(zfs get -H -o value mountpoint "$dataset")" = ${root}
    mountpoint -q ${root} || zfs mount "$dataset"
    install -d -m0700 -o ${account} -g ${account} ${root} ${root}/state ${root}/logs ${root}/logs/service
    if test ! -e ${root}/DEMO; then
      printf '%s\n' 'osctl-repo-server synthetic demo v1' > ${root}/DEMO
      chmod 0400 ${root}/DEMO
      chown ${account}:${account} ${root}/DEMO
    fi
    test "$(cat ${root}/DEMO)" = 'osctl-repo-server synthetic demo v1'
    install -d -m0755 -o ${account} -g ${account} ${sockets}
  '';
  seed = pkgs.writeShellScriptBin "osctl-repo-demo-seed" ''
    set -euo pipefail
    test "$#" -eq 0
    exec ${pkgs.coreutils}/bin/timeout --kill-after=5 180 ${pkgs.runit}/bin/chpst -u ${account}:${account} \
      ${pkgs.ruby}/bin/ruby ${../lib/image-repository-seed.rb} \
      ${root} ${binary} ${toString limits.leaseSeconds}
  '';
  maintenance = pkgs.writeShellScript "repository-demo-maintenance" ''
    set -euo pipefail
    test -S ${sockets}/admin.sock || exit 0
    exec 9>${sockets}/maintenance.lock
    ${pkgs.util-linux}/bin/flock -n 9 || exit 0
    for operation in expire reclaim; do
      request_id=$(cat /proc/sys/kernel/random/uuid)
      printf '{"request_id":"%s","operation":"%s","repository":"demo","params":{}}\n' "$request_id" "$operation" \
        | ${pkgs.coreutils}/bin/timeout 30 ${binary} ctl --socket ${sockets}/admin.sock \
        | ${pkgs.jq}/bin/jq -e '.ok == true' >/dev/null
    done
  '';
in
assert
  valid
  || throw "imageRepository limits must be finite demo bounds (3-8 runs, 1h-24h lease, at most 64MiB payload/8MiB upload)";
{
  users.groups = lib.genAttrs [
    account
    "repo-demo-producer"
    "repo-demo-publisher"
    "repo-demo-admin"
  ] (_: { });
  users.users.${account} = {
    isSystemUser = true;
    group = account;
    extraGroups = [
      "repo-demo-producer"
      "repo-demo-publisher"
      "repo-demo-admin"
    ];
  };
  environment.systemPackages = [ server ] ++ lib.optional settings.seed seed;
  runit.services.osctl-repo-server-demo = {
    run = ''
      set -e
      waitForService pool-tank
      ${prepare}
      exec ${pkgs.runit}/bin/chpst -u ${account}:${account}:repo-demo-producer:repo-demo-publisher:repo-demo-admin \
        ${binary} serve --root ${root}/state --listen 127.0.0.1:8080 --repository demo --instance synthetic-demo \
        --producer-socket ${sockets}/producer.sock --producer-group repo-demo-producer \
        --publisher-socket ${sockets}/publisher.sock --publisher-group repo-demo-publisher \
        --admin-socket ${sockets}/admin.sock --admin-group repo-demo-admin \
        --max-bytes ${toString limits.maxBytes} --reserve-bytes ${toString limits.reserveBytes} \
        --max-upload-bytes ${toString limits.maxUploadBytes} --max-runs ${toString limits.maxRuns} \
        --max-lease ${toString limits.leaseSeconds}s --export-lease 1h \
        --access-log ${root}/logs/access.jsonl --access-log-max-bytes 1048576 --access-log-files 2 \
        --stats-days 7 --stats-max-rows 256 --event-queue 64 \
        --client-ip-header X-Repo-Client-IP --trusted-proxy 127.0.0.1/32
    '';
    check = "test -S ${sockets}/admin.sock";
    log = {
      enable = true;
      run = ''
        set -e
        source ../helpers
        waitForService pool-tank
        ${prepare}
        printf 's1048576\nn2\n' > ${root}/logs/service/config
        exec ${pkgs.runit}/bin/chpst -u ${account}:${account} \
          ${pkgs.runit}/bin/svlogd -tt ${root}/logs/service
      '';
    };
  };
  services.cron.systemCronJobs = [ "17 * * * * ${account} ${maintenance}" ];
}
