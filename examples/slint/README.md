# Slint example

This Phoenix application uses Rekindle with one Slint client for Web and
desktop.

```console
mix setup
mix phx.server
```

Open [localhost:4000](http://localhost:4000) for the Web client. Run
`mix rekindle.dev desktop` in another terminal for native development. Rust
dependencies and entry points live in [`client/`](client/).
