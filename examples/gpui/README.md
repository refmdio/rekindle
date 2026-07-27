# GPUI example

This Phoenix application uses Rekindle with a shared GPUI client for Web and
desktop.

Prepare the toolchain and start both targets:

```console
mix setup
mix phx.server
```

Open [localhost:4000](http://localhost:4000) for the Web client. The native
client is built and restarted by the same development command. Cargo
dependencies, features, and entry points are in [`client/`](client/).

GPUI Web requires WebGPU in a secure browser context. `localhost` qualifies;
plain HTTP through a LAN address does not.
