# Production Builds

Rekindle publishes production artifacts from the same Mix entry point used
during development. Web and desktop publication use target-specific output
formats while sharing configuration and Cargo execution.

## Build Phoenix assets

Build and digest all Phoenix assets, including the Rekindle Web target:

```console
mix assets.deploy
```

The installer places the Rekindle release build before `phx.digest`.

## Build a target explicitly

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
result.metadata.generation
```

`Rekindle.build/2` returns typed errors for configuration, Cargo, toolchain, and
publication failures.

## Phoenix Web entry

The installer replaces the Phoenix root layout's rendered page content with the
selected plugin's Web host, adds its full-page CSS to the document head,
and loads the logical Web entry module. A custom egui layout uses the equivalent
of:

```heex
<style>
  <%= Phoenix.HTML.raw(Rekindle.Phoenix.web_style(Rekindle.Plugin.Egui)) %>
</style>
<%= Phoenix.HTML.raw(Rekindle.Phoenix.web_host(Rekindle.Plugin.Egui)) %>
<script
  type="module"
  src={Rekindle.Phoenix.web_entry_path(MyAppWeb.Endpoint)}
></script>
```

`web_style/1` and `web_host/1` return shell content declared by the configured
plugin, so applications should only configure trusted plugin modules.
`web_entry_path/1` resolves through the endpoint's static manifest after
`phx.digest`; loading that module starts the selected immutable Web generation.

The helper functions remain public for applications that intentionally move
the generated host or script to another layout.

Rekindle publishes each complete generation below
`priv/static/rekindle/web/` and updates `priv/static/rekindle/entry.js` only
after publication succeeds. Phoenix can then add digested and compressed
derivatives to those files.

The generated Phoenix static Plug reads `:public_dir` from the Rekindle
configuration. A custom directory must be an absolute path so the build and
runtime resolve the same location. For another Plug-compatible host, mount that
directory as static content and load `/rekindle/entry.js`.
