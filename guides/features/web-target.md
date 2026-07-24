# Web Target

The Web target compiles the selected Rust UI integration to WebAssembly and
publishes the JavaScript, WebAssembly, and public files as one immutable
generation.

## Development

`mix rekindle.dev` watches the client and publishes successful builds below
`.rekindle/dev`. Connected browsers are notified only after a complete
generation is available. A failed build leaves the previous generation active.

Run one build without the development server:

```console
mix rekindle.build web
```

## Production

```console
mix rekindle.build web --release
```

By default, generations are published below:

```text
priv/static/rekindle/web/<generation>/
priv/static/rekindle/web-current.json
```

The selector identifies the current complete generation. The installer adds a
static endpoint at `/rekindle` and prepends the release build to
`assets.deploy`, before `phx.digest`.

## Browser requirements

GPUI requires WebGPU. The egui and Slint templates use WebGL2. Browser graphics
APIs can require hardware acceleration and a supported adapter.

WebGPU also requires a secure context. `http://localhost` is treated as
potentially trustworthy, but an HTTP address accessed from another device is
not. Use HTTPS for remote development and deployment.
