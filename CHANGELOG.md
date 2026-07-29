# Changelog

## Unreleased

## 0.1.9 - 2026-07-29

- Run each configured Cargo package's unit, integration, documentation, and
  framework headless UI tests through the application's regular `mix test`
  suite.
- Keep `mix rekindle.check` focused on Rust formatting and Clippy.

## 0.1.8 - 2026-07-29

- Add built-in Iced support for Web and native desktop targets.
- Align the generated framework examples and their static asset delivery.
- Resize Slint Web clients with the browser viewport.

## 0.1.7 - 2026-07-28

- Make Phoenix integration optional and support installation into plain Mix
  projects.
- Simplify Web and desktop artifact publication while preserving complete
  outputs during replacement.
- Run Rekindle setup before asset builds and apply installer defaults when
  target options are omitted.
- Validate plugin Cargo dependencies and resolve custom publication paths
  consistently.

## 0.1.6 - 2026-07-28

- Replace the fixed framework registry with a public plugin contract.
- Generate Cargo manifests from plugin specifications while keeping Cargo
  authoritative after installation.
- Let external Igniter packages provide client resources and delegate project
  installation to Rekindle.
- Configure framework support exclusively through plugin modules and keep
  generated Cargo projects application-owned.

## 0.1.5 - 2026-07-28

- Make the generated Rust Web UI the primary Phoenix page surface for GPUI,
  egui, and Slint.
- Preserve each framework's upstream starter UI across Web and desktop
  targets.
- Keep the Slint Web event loop and UI instance alive after startup.
- Serve WebAssembly with the standard `application/wasm` media type.
- Keep freshly installed Phoenix projects formatted and passing their default
  controller tests.

## 0.1.4 - 2026-07-28

- Start one supervised Web development runtime from the first
  `Rekindle.DevServer` request, without a Phoenix endpoint watcher.
- Run headless Web or native desktop development explicitly through
  `mix rekindle.dev`.
- Separate enabled build targets from the target selected for development and
  default combined projects to Web.
- Serve development Web generations through the host-independent
  `Rekindle.DevServer` Plug.
- Allow Web release publication below a configured `:public_dir`.
- Route build notifications only to their target-specific development runtime.

## 0.1.3 - 2026-07-28

- Use Phoenix's standard `mix phx.server` command for development and remove
  the redundant `mix rekindle.dev` wrapper.
- Integrate Web builds with `mix assets.build`, simplify generated target
  configuration, and preserve application-owned Rust UI source.
- Add concise build timing, browser loading and failure feedback, and Web
  development lifecycle events.
- Integrate target-aware Rust formatting, Clippy, and library checks with
  Phoenix's `mix precommit` alias.

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
