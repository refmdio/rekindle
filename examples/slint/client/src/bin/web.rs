#![no_main]

use std::cell::OnceCell;

use slint::ComponentHandle;
use wasm_bindgen::{JsCast, closure::Closure};

thread_local! {
    static UI: OnceCell<client::AppWindow> = const { OnceCell::new() };
    static RESIZE_HANDLER: OnceCell<Closure<dyn FnMut()>> = const { OnceCell::new() };
}

fn resize_to_viewport(ui: &client::AppWindow) {
    let window = web_sys::window().expect("missing browser window");
    let width = window
        .inner_width()
        .expect("failed to read viewport width")
        .as_f64()
        .expect("viewport width is not a number");
    let height = window
        .inner_height()
        .expect("failed to read viewport height")
        .as_f64()
        .expect("viewport height is not a number");

    ui.window()
        .set_size(slint::LogicalSize::new(width as f32, height as f32));

    let ui_handle = ui.as_weak();
    let redraw = Closure::once_into_js(move || {
        if let Some(ui) = ui_handle.upgrade() {
            ui.window().request_redraw();
        }
    });
    window
        .request_animation_frame(redraw.unchecked_ref())
        .expect("failed to schedule redraw");
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

    let ui_handle = ui.as_weak();
    let resize_handler = Closure::new(move || {
        if let Some(ui) = ui_handle.upgrade() {
            resize_to_viewport(&ui);
        }
    });
    let window = web_sys::window().expect("missing browser window");
    window
        .add_event_listener_with_callback("resize", resize_handler.as_ref().unchecked_ref())
        .expect("failed to listen for viewport resize");
    window
        .request_animation_frame(resize_handler.as_ref().unchecked_ref())
        .expect("failed to schedule initial viewport resize");
    RESIZE_HANDLER.with(|slot| {
        assert!(
            slot.set(resize_handler).is_ok(),
            "the resize handler is already installed"
        );
    });

    UI.with(|slot| {
        assert!(slot.set(ui).is_ok(), "the application is already running");
    });

    slint::run_event_loop().expect("failed to run the application");
}
