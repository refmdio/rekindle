# Getting Started

This guide covers installation into an existing Phoenix application. For a new
application, use the `mix igniter.new` command shown in the README.

Rekindle 0.1 supports native development and desktop release builds on
`x86_64-unknown-linux-gnu`.

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
client, Rekindle selects GPUI and enables both targets. The Web target is
`wasm32-unknown-unknown`; Rekindle 0.1 qualifies desktop builds on
`x86_64-unknown-linux-gnu`.

The installer adds Rekindle as an application dependency, creates the Rust
client, configures the Phoenix development runtime, and adds Web release
building to `assets.deploy`.

## Existing client directory

Rekindle does not overwrite an existing `client/Cargo.toml`. Move or rename an
unmanaged `client/` directory before installation.

## Next steps

Read [How Rekindle Works](how-rekindle-works.md) for the generated client
layout, then continue with [Configuration](../features/configuration.md) or
[Development](../features/development.md).
