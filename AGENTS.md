# Development Guidelines

This repository owns the vpsFree.cz extensions for the generic
`aither64/dev-workspace` runtime. It contains KB tools, vpsAdmin and vpsAdminOS
development-cluster providers, workspace skills, and the namespace migration
helper.

- Keep deployment hostnames, credentials, and operational cluster defaults in
  the consuming workspace. The Nix package must require them through
  `siteConfig`.
- Keep the tracked tree free of personal host naming. The
  `organization-source` flake check enforces this boundary.
- Run focused Ruby tests before `nix flake check --print-build-logs`.
- When editing actions, verify current releases from the official action
  repositories before changing `uses:` references.
- Use functional commits and write commit messages through a file passed to
  `git commit -F`.

## Workspace integration and migration

For workspace integration and namespace migration, the local operator is
trusted to administer the development host. Root/user ownership assigns
operational responsibility and does not contain that operator. Do not add
checks or tests solely for an already compromised operator's filesystem
manipulation. Preserve ordinary path and ownership checks, serialization,
credential integrity, retry and rollback behavior.

This assumption applies only to workspace integration and namespace migration.
It does not weaken KB publication approval, remote-client validation, guest/host
boundaries or security requirements in the projects being developed. Include
this scope in review packets for workspace changes.

The normal flake checks include the Ruby migration tests and host-path contract.
Run `nix build --no-link --print-build-logs .#host-migration-test` after review
when migration behavior or its upstream host-state compatibility contract
changes. The Host migration workflow runs on `master` for local migration and
contract files. After mandatory review, run feature-branch and upstream contract
checks with the local command above. Manual dispatch is also available once the
workflow exists on the default branch. Keep normal dependency-update CI within
the 20-minute target; do not add the migration VM back to every package update.
