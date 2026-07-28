#![no_main]

use std::cell::OnceCell;

use slint::ComponentHandle;

thread_local! {
    static UI: OnceCell<client::AppWindow> = const { OnceCell::new() };
}

#[wasm_bindgen::prelude::wasm_bindgen(start)]
pub fn start() {
    let backend = i_slint_backend_winit::Backend::builder()
        .with_spawn_event_loop(true)
        .build()
        .expect("failed to initialize the Slint Web backend");

    slint::platform::set_platform(Box::new(backend))
        .expect("failed to install the Slint Web backend");

    let ui = client::create().expect("failed to create the application");
    ui.show().expect("failed to show the application");
    UI.with(|slot| {
        assert!(slot.set(ui).is_ok(), "the application is already running");
    });

    slint::run_event_loop().expect("failed to run the application");
}
