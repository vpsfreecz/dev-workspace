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
