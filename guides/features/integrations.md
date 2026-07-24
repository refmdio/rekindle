# Integrations

Rekindle provides project templates for GPUI, egui/eframe, and Slint. An
integration selects the Rust dependencies, platform bootstrap code, browser
host element, and graphics backend expected by the generated client.

## GPUI

```console
mix igniter.install rekindle --integration gpui --targets web,desktop
```

GPUI uses its Web platform for the browser target and its native platform for
desktop. The browser target requires WebGPU.

## egui/eframe

```console
mix igniter.install rekindle --integration egui --targets web,desktop
```

The generated Web entry mounts eframe into a canvas and uses WebGL2. The desktop
entry uses eframe's native runtime. The shared `TemplateApp` lives in
`client/src/app.rs`, following the official eframe template layout.

## Slint

```console
mix igniter.install rekindle --integration slint --targets web,desktop
```

The generated Web entry mounts Slint into a canvas and uses WebGL2. The desktop
entry uses Slint's native runtime. The generated `build.rs` compiles
`client/ui/app-window.slint`, while `client/src/lib.rs` connects the component's
callbacks for both targets.

## Shared UI code

Every integration keeps one shared application implementation for Web and
desktop. GPUI uses `client/src/lib.rs`; eframe follows its official
`client/src/app.rs` plus `client/src/lib.rs` layout; Slint keeps its UI in
`client/ui/app-window.slint` with shared Rust bindings in `client/src/lib.rs`.
The `web` and `desktop` binaries contain platform startup code only.
Target-specific behavior can be selected with the generated Cargo features.

Re-running the installer does not replace an existing Cargo client. Adoption
validates an isolated copy, so the existing crate and its lockfile state remain
unchanged. See [Getting Started](../introduction/getting-started.md) for the
required target entries.
