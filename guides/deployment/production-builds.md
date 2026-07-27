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

The installer adds the selected integration's host markup and logical Web entry
module to the Phoenix root layout. An egui installation, for example, adds the
equivalent of:

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

The helper functions remain public for applications that intentionally move
the generated host or script to another layout.

Rekindle publishes each complete generation below
`priv/static/rekindle/web/` and updates `priv/static/rekindle/entry.js` only
after publication succeeds. Phoenix can then add digested and compressed
derivatives to those files.
