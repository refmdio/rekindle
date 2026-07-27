# GPUI example

This Phoenix application uses Rekindle with a shared GPUI client for Web and
desktop.

From this directory, prepare the toolchain and start development:

```console
mix setup
mix rekindle.dev
```

Open [localhost:4000](http://localhost:4000) for the Web client. The native
client is built and restarted by the same development command.

The example depends on the Rekindle checkout at `../..`. Cargo dependencies,
features, and entry points are in [`client/`](client/).

GPUI Web requires WebGPU in a secure browser context. `localhost` qualifies;
plain HTTP through a LAN address does not.
