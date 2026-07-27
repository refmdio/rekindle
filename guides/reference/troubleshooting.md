# Troubleshooting

Start with Rekindle's diagnostics:

```console
mix rekindle.doctor
```

The command does not modify the project.

## The Web tool is missing

Run:

```console
mix rekindle.setup web
```

Rekindle installs its pinned `wasm-bindgen-cli` into a versioned user cache.
There is no need to install or replace a global copy.

## Cargo reports a missing target

Run `mix rekindle.setup` and follow any target-specific diagnostic. The selected
integration may also require native system libraries that are outside
Rekindle's control.

Rekindle 0.1 accepts desktop builds only when `rustc -vV` reports
`x86_64-unknown-linux-gnu`. A different host is reported as unsupported rather
than treated as a qualified release target.

## Development builds do not start

The Rekindle development supervisor starts only when the configured Phoenix
endpoint has `code_reloader: true`. Use the development Mix environment and
start the application with:

```console
mix rekindle.dev
```

## A remote browser cannot use WebGPU

WebGPU is restricted to secure contexts. `http://localhost` is treated as
potentially trustworthy, but an HTTP address on another device is not. Serve
remote development and deployed applications over HTTPS.

This differs from a graphics adapter failure in a secure context. For that
case, check browser support and hardware acceleration.

## A rebuild fails

Rekindle reports Cargo diagnostics without replacing the last successful Web
generation or running desktop process. Correct the Rust error and save the
client source again, or run an explicit target build:

```console
mix rekindle.build web
mix rekindle.build desktop
```
