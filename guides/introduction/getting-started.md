# Getting Started

This guide covers installation into an existing Phoenix application. For a new
application, use the `mix igniter.new` command shown in the README.

## Add Rekindle to an existing Phoenix application

Add Igniter to the application's development dependencies:

```elixir
def deps do
  [
    {:igniter, "~> 0.8", only: [:dev, :test]}
  ]
end
```

Fetch the dependency, then install Rekindle:

```console
mix deps.get
mix igniter.install rekindle --integration gpui --targets web,desktop
```

Valid integrations are `gpui`, `egui`, and `slint`. Valid target selections are
`web`, `desktop`, and `web,desktop`. When the flags are omitted for a new
client, Rekindle selects GPUI and enables both targets.

The installer adds Rekindle as an application dependency, creates or adopts the
Rust client, configures the Phoenix development runtime, and adds Web release
building to `assets.deploy`.

## Adopt an existing Rust client

Rekindle does not overwrite an existing `client/Cargo.toml`. To adopt one,
supply the integration and targets explicitly:

```console
mix igniter.install rekindle --integration egui --targets web,desktop
```

The selected entries must already exist at `client/src/bin/web.rs` and
`client/src/bin/desktop.rs`. Rekindle validates the Cargo package and selected
integration before changing the project.

## Next steps

Read [How Rekindle Works](how-rekindle-works.md) for the generated client
layout, then continue with [Configuration](../features/configuration.md) or
[Development](../features/development.md).
