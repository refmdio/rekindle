# Getting Started

This guide covers installation into an existing Phoenix application. For a new
application, use the `mix igniter.new` command shown in the README.

Desktop builds use the host target reported by `rustc -vV`.

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
mix igniter.install rekindle --plugin gpui --targets web,desktop
```

Valid plugins are `gpui`, `egui`, `slint`, and `iced`. Valid target selections
are `web`, `desktop`, and `web,desktop`. When the flags are omitted for a new
client, Rekindle selects GPUI and enables both targets. The Web target is
`wasm32-unknown-unknown`; desktop builds use the Rust host target.

The installer adds `Rekindle.DevServer` to the Phoenix endpoint. The first
request starts Web development automatically, so the normal command remains
`mix phx.server`. Run `mix rekindle.dev desktop` when developing the native
application, or `mix rekindle.dev web,desktop` to select both targets
explicitly.

The installer adds Rekindle as an application dependency, creates the Rust
client, configures the Phoenix development runtime, and adds Web builds to the
standard `assets.build` and `assets.deploy` aliases.

## Existing client directory

Rekindle does not overwrite an existing `client/Cargo.toml`. Move or rename an
unmanaged `client/` directory before installation.

## Next steps

Read [How Rekindle Works](how-rekindle-works.md) for the generated client
layout, then continue with [Configuration](../features/configuration.md) or
[Development](../features/development.md).
