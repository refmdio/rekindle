# Production Builds

Rekindle publishes production artifacts from the same Mix entry point used
during development. Web and desktop publication use target-specific output
formats while sharing configuration and Cargo execution.

## Build a release artifact

Use the target's configured Cargo release profile:

```console
mix rekindle.build web --release
mix rekindle.build desktop --release
```

See [Web Target](../features/web-target.md) and
[Desktop Target](../features/desktop-target.md) for their output layouts and
runtime requirements.

## Programmatic builds

The Mix tasks and Elixir API use the same build pipeline:

```elixir
{:ok, result} =
  Rekindle.build(:web,
    otp_app: :my_app,
    profile: :release
  )

result.artifact
result.metadata.manifest
```

`Rekindle.build/2` returns typed errors for configuration, Cargo, toolchain, and
publication failures.
