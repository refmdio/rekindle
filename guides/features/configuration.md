# Configuration

Rekindle uses the host application's standard Elixir configuration:

```elixir
config :my_app, Rekindle,
  integration: :gpui,
  targets: [
    web: [features: ["web"]],
    desktop: [features: ["desktop"]]
  ]
```

## Top-level options

- `:integration` — required; `:gpui`, `:egui`, or `:slint`.
- `:targets` — required; a non-empty keyword list containing `:web`,
  `:desktop`, or both.
- `:public_dir` — project-relative Web publication directory. Defaults to
  `"priv/static"` and must remain inside the project.

## Target options

Each target accepts:

- `:features` — Cargo features enabled for the target. Defaults to an empty
  list when configuring an adopted client.
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
  public_dir: "priv/static",
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
