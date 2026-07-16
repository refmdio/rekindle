# Rekindle

Rekindle is a Phoenix-native build system and development runtime for Rust GPUI
applications targeting WebAssembly, native desktop, or both.

The project is under active development.

## Installation

Igniter is the canonical installation path for a new or existing Phoenix
application:

```sh
mix igniter.install rekindle \
  --client-path client \
  --targets web,desktop \
  --endpoint MyAppWeb.Endpoint
```

The installer generates the GPUI client, adds the Rekindle configuration and
supervision child, registers the development socket and plug, exposes projected
Web assets, updates Phoenix asset aliases, and adds one page marker.

## Manual installation

The following procedure is the supported manual equivalent of the command
above. Replace `:my_app`, `MyApp`, and `MyAppWeb` with the names from the host
Phoenix application. The example enables both Web and desktop targets and uses
the default `client/` location.

Add Rekindle to `mix.exs`, then fetch dependencies:

```elixir
defp deps do
  [
    {:rekindle, "~> 0.1"}
  ]
end
```

```sh
mix deps.get
```

Generate the canonical GPUI client and `Cargo.lock` with Rekindle's pinned Web
toolchain. The destination must be absent or empty. This uses the same typed
generation path as the Igniter installer.

```sh
mix run -e '{:ok, _files} = Rekindle.ClientGenerator.write("client", application_id: "my_app", package: "my_app_ui", web_binary: "my_app-web", desktop_binary: "my_app", targets: [:web, :desktop])'
```

Add the build configuration to `config/config.exs` before the final
`import_config` call:

```elixir
config :my_app,
  rekindle_build: [
    schema: 1,
    client: "client",
    targets: [
      web: [
        package: "my_app_ui",
        binary: "my_app-web",
        toolchain: [kind: :rustup, name: "nightly-2026-04-01"],
        rust_target: "wasm32-unknown-unknown",
        features: ["web"],
        default_features: false,
        profiles: [dev: "dev", release: "release"],
        environment: [
          inherit: :toolchain,
          set: [],
          unset: [],
          build_inputs: [],
          redact: []
        ],
        public: "client/public",
        hot_styles: [],
        projection: [mode: :phoenix_static, root: "priv/static/rekindle"]
      ],
      desktop: [
        package: "my_app_ui",
        binary: "my_app",
        toolchain: [kind: :rustup, name: "1.95.0"],
        features: ["desktop"],
        default_features: false,
        profiles: [dev: "dev", release: "release"],
        environment: [
          inherit: :toolchain,
          set: [],
          unset: [],
          build_inputs: [],
          redact: []
        ],
        runtime: [
          readiness: :ipc_v1,
          startup_timeout_ms: 10_000,
          shutdown_timeout_ms: 3_000,
          replacement: :overlap,
          handoff: :enabled
        ],
        projection: [mode: :directory, root: "dist/rekindle/desktop"]
      ]
    ]
  ]
```

Add the development configuration to `config/dev.exs`:

```elixir
config :my_app,
  rekindle_dev: [
    schema: 1,
    enabled: true,
    targets: [:web],
    endpoint: MyAppWeb.Endpoint,
    accepted_origins: :endpoint
  ]
```

Append the Rekindle child to the existing literal children list in
`MyApp.Application`. The guard keeps the development runtime out of production
releases:

```elixir
children =
  existing_children ++
    if Code.ensure_loaded?(Mix) and Mix.env() != :prod do
      [{Rekindle, otp_app: :my_app, name: MyApp.Rekindle}]
    else
      []
    end
```

Inside `MyAppWeb.Endpoint`, place the development registration before the
router plug:

```elixir
if code_reloading? do
  socket "/_rekindle/socket", Rekindle.Phoenix.Socket,
    websocket: true,
    longpoll: false

  plug Rekindle.Phoenix.DevPlug, otp_app: :my_app
end

plug MyAppWeb.Router
```

Add `"rekindle"` once to `MyAppWeb.static_paths/0` so Phoenix can serve the
projected artifact:

```elixir
def static_paths, do: ~w(assets images favicon.ico rekindle)
```

Add exactly one page marker before the closing `</body>` in
`lib/my_app_web/components/layouts/root.html.heex`:

```heex
<Rekindle.Phoenix.Components.gpui_page
  otp_app={:my_app}
  endpoint={MyAppWeb.Endpoint}
/>
```

Keep existing asset commands and make the Rekindle steps terminal. Replace the
single terminal `phx.digest` step; do not retain both digest commands.

```elixir
defp aliases do
  [
    "assets.build": existing_asset_build_steps ++ ["rekindle.build web"],
    "assets.deploy": existing_pre_digest_steps ++ ["rekindle.phoenix.deploy"]
  ]
end
```

Add the generated and projected paths to `.gitignore`:

```gitignore
/.rekindle/
/priv/static/rekindle/
/dist/rekindle/desktop/
/client/.rekindle/
```

Finally, verify the configured Rust targets and helper:

```sh
mix rekindle.setup
```

The executable equivalence fixture in
`test/rekindle/igniter_test.exs` compares this procedure with the Igniter
installation across dependency, configuration, client, supervision, Phoenix,
alias, page-marker, and ignore-file surfaces while retaining host-owned
content.
