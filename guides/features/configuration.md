# Configuration

Rekindle uses the host application's standard Elixir configuration:

```elixir
config :my_app, Rekindle,
  integration: :gpui,
  targets: [
    web: [],
    desktop: []
  ]
```

## Top-level options

- `:integration` — required; `:gpui`, `:egui`, or `:slint`.
- `:targets` — required; a non-empty keyword list containing `:web`,
  `:desktop`, or both.
- `:public_dir` — Web release publication root, relative to the Elixir project
  unless absolute. Defaults to `"priv/static"`.

The Rust client is located at `client/`. Web release output is published below
`<public_dir>/rekindle/`.

## Target options

Each target accepts:

- `:features` — Cargo features enabled for the target. Defaults to the target
  name (`"web"` or `"desktop"`). Set `features: []` explicitly when the Cargo
  target does not require a feature.
- `:package` — Cargo package name when the workspace contains more than one
  package.
- `:binary` — Cargo binary name when it cannot be selected from the target
  entry.
- `:profiles` — Cargo profile names for Rekindle's `:dev` and `:release`
  modes. Defaults to `[dev: "dev", release: "release"]`.

For example:

```elixir
config :my_app, Rekindle,
  integration: :egui,
  targets: [
    web: [
      package: "editor_client",
      binary: "web",
      features: ["web"],
      profiles: [dev: "dev", release: "release"]
    ],
    desktop: [
      package: "editor_client",
      binary: "desktop",
      features: ["desktop"],
      profiles: [dev: "dev", release: "release"]
    ]
  ]
```

`mix rekindle.doctor` validates the effective configuration and Cargo metadata
without changing the project.
