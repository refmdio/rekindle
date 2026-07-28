# Integrations

Rekindle provides project templates for GPUI, egui/eframe, and Slint. An
integration selects the Rust dependencies, platform bootstrap code, browser
host, Web shell CSS, and graphics backend expected by the generated client. The
installer makes that shell the Phoenix root layout's primary surface, so Web
and desktop start with the same shared Rust UI.

## GPUI

```console
mix igniter.install rekindle --integration gpui --targets web,desktop
```

GPUI uses its Web platform for the browser target and its native platform for
desktop. The browser target requires WebGPU and creates its own canvas.
Rekindle installs the full-page canvas rules used by GPUI Web's hello example.

## egui/eframe

```console
mix igniter.install rekindle --integration egui --targets web,desktop
```

The generated Web entry mounts eframe into a canvas and uses WebGL2. The desktop
entry uses eframe's native runtime. The shared `TemplateApp` lives in
`client/src/app.rs`, following the official eframe template layout.
The generated Web shell uses the official template's full-page canvas layout.

## Slint

```console
mix igniter.install rekindle --integration slint --targets web,desktop
```

The generated Web entry mounts Slint into a canvas and uses WebGL2. The desktop
entry uses Slint's native runtime. The generated `build.rs` compiles
`client/ui/app-window.slint`, while `client/src/lib.rs` connects the component's
callbacks for both targets. The generated Web shell gives the shared Slint
window the complete browser surface.

## Shared UI code

Every integration keeps one shared application implementation for Web and
desktop. GPUI uses `client/src/lib.rs`; eframe follows its official
`client/src/app.rs` plus `client/src/lib.rs` layout; Slint keeps its UI in
`client/ui/app-window.slint` with shared Rust bindings in `client/src/lib.rs`.
The `web` and `desktop` binaries contain platform startup code only.
Target-specific behavior can be selected with the generated Cargo features.

Re-running the installer preserves the generated Cargo client. The installer
does not overwrite an unmanaged `client/Cargo.toml`.
