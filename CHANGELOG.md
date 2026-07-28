# Changelog

## Unreleased

- Use Phoenix's standard `mix phx.server` command for development and remove
  the redundant `mix rekindle.dev` wrapper.
- Integrate Web builds with `mix assets.build`, simplify generated target
  configuration, and allow the installer to add a target without replacing
  existing Rust UI source.

## 0.1.2 - 2026-07-28

- Resolve Cargo through rustup using the generated client toolchain.

## 0.1.1 - 2026-07-27

- Simplified external process ownership, artifact publication, and installation.
- Fixed Phoenix development entry resolution and runtime startup behavior.
- Added staged desktop release replacement and stricter process option validation.
- Added automated architecture, dead-code, and code-smell checks.
- Fixed Web publication at `priv/static/rekindle` and removed the `:public_dir` option.
- Restricted installation to newly generated clients instead of adopting an existing `client/`.
- Replaced retained desktop generations and restart rollback with a single current executable.

## 0.1.0 - 2026-07-24

- Initial release.
