# Web Target

The Web target compiles the selected Rust UI integration to WebAssembly and
publishes the JavaScript, WebAssembly, and public files as one immutable
generation.

## Development

The Phoenix installer adds `Rekindle.DevServer` to the development endpoint.
The first request starts the Web builder and client watcher, and successful
builds are published below `.rekindle/dev`. The browser runtime detects a new
generation only after it is complete. A failed build leaves the previous
generation active.

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
priv/static/rekindle/entry.js
```

Set the top-level `:public_dir` option to publish below another host-controlled
static directory.

The entry module imports and starts the selected complete generation. It is
replaced only after that generation has been published. The installer adds a
static endpoint at `/rekindle`, appends development building to `assets.build`,
and prepends the release build to `assets.deploy` before `phx.digest`. The
current and immediately previous generation are retained. Phoenix may add
digested and compressed derivatives to the published files.

## Browser requirements

GPUI requires WebGPU. The egui and Slint templates use WebGL2. Browser graphics
APIs can require hardware acceleration and a supported adapter.

WebGPU also requires a secure context. `http://localhost` is treated as
potentially trustworthy, but an HTTP address accessed from another device is
not. Use HTTPS for remote development and deployment.
