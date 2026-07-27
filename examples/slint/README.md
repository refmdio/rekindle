# Slint example

This Phoenix application uses Rekindle with a shared Slint client for Web and
desktop.

Prepare the toolchain and start both targets:

```console
mix setup
mix phx.server
```

Open [localhost:4000](http://localhost:4000) for the Web client. The native
client is built and restarted by the same development command. Cargo
dependencies, features, and entry points are in [`client/`](client/).
