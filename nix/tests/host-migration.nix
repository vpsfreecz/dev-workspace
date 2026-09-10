{
  devWorkspace,
  migrationPackage,
  pkgs,
}:
pkgs.testers.runNixOSTest {
  name = "vpsfree-dev-workspace-host-migration";

  nodes.machine =
    { lib, ... }:
    {
      imports = [ devWorkspace.nixosModules.host ];

      users.users.developer.isNormalUser = true;
      services.dev-workspaces = {
        enable = true;
        owner = "developer";
        hostName = "workspace.example.test";
        wildcardHost = "*.workspace.example.test";
        aliases = [ "legacy-workspace.example.test" ];
      };

      system.activationScripts.devWorkspaceCredentials.text = lib.mkForce "";
      systemd.timers.workspace-portal-certificate-renewal.wantedBy = lib.mkForce [ ];
      systemd.services.nginx.wantedBy = lib.mkForce [ ];
      environment.systemPackages = [ migrationPackage ];
      system.stateVersion = "26.05";
    };

  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")

    reconcile = "/run/current-system/sw/bin/workspace-portal-substrate-reconcile"
    migration = "${migrationPackage}/libexec/vpsfree-dev-workspace-migrate"
    old_paths = [
        "/var/lib/vpsfree-workspace-portal-password",
        "/var/lib/vpsfree-workspace-portal-auth",
        "/var/lib/vpsfree-workspace-pki",
        "/var/lib/vpsfree-workspace-portal-tls",
        "/var/lib/vpsfree-workspace-portal-public",
        "/run/vpsfree-workspace-router",
        "/run/lock/vpsfree-workspace-portal-substrate.lock",
    ]
    new_paths = [
        "/var/lib/dev-workspaces/password",
        "/var/lib/dev-workspaces/auth",
        "/var/lib/dev-workspaces/pki",
        "/var/lib/dev-workspaces/tls",
        "/var/lib/dev-workspaces/public",
        "/run/dev-workspaces",
        "/run/lock/dev-workspace-substrate.lock",
    ]

    def snapshot(paths):
        quoted = " ".join(paths)
        return machine.succeed(
            "for path in " + quoted + "; do "
            "find \"$path\" -printf 'metadata\\t%p\\t%y\\t%m\\t%U\\t%G\\t%l\\n'; "
            "find \"$path\" -type f -exec sha256sum -- '{}' \\;; "
            "done | LC_ALL=C sort"
        )

    machine.succeed(reconcile)
    for source, target in zip(new_paths, old_paths):
        machine.succeed(f"mkdir -p $(dirname {target}); mv -T {source} {target}")

    original = snapshot(old_paths)
    machine.succeed(f"{migration} preflight --direction forward --scope host")
    machine.succeed(f"{migration} forward --scope host --yes")
    migrated = snapshot(new_paths)

    machine.succeed(reconcile)
    assert snapshot(new_paths) == migrated
    machine.succeed(f"{migration} preflight --direction reverse --scope host")
    machine.succeed(f"{migration} reverse --scope host --yes")
    assert snapshot(old_paths) == original

    machine.succeed(
        "test -L /var/lib/vpsfree-workspace-portal-tls/current; "
        "case $(readlink /var/lib/vpsfree-workspace-portal-tls/current) in "
        "pairs/pair-*) ;; *) exit 1 ;; esac; "
        "test -f /var/lib/vpsfree-workspace-pki/authority/ca-key.pem; "
        "test -f /var/lib/vpsfree-workspace-pki/authority/ca.pem; "
        "test -f /var/lib/vpsfree-workspace-portal-password/password; "
        "test -f /var/lib/vpsfree-workspace-portal-auth/htpasswd"
    )
  '';
}
