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

## Phoenix Web entry

Render the selected integration's host markup before loading the logical Web
entry module. For example, an egui application can use this HEEx:

```heex
<%= Phoenix.HTML.raw(Rekindle.Phoenix.web_host(:egui)) %>
<script
  type="module"
  src={Rekindle.Phoenix.web_entry_path(MyAppWeb.Endpoint)}
></script>
```

`web_host/1` returns fixed trusted markup owned by the integration. GPUI returns
an empty string, egui returns `<canvas id="the_canvas_id"></canvas>`, and Slint
returns `<canvas id="canvas"></canvas>`. `web_entry_path/1` resolves through the
endpoint's static manifest after `phx.digest`; loading that module starts the
selected immutable Web generation.

The exact Rekindle generation remains under `.rekindle/release`. Its
`priv/static` copy is deployment output, so Phoenix can add digested and
compressed derivatives without changing the canonical generation identity.
