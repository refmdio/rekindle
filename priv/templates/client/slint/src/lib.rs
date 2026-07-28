use slint::ComponentHandle;

slint::include_modules!();

pub fn create() -> Result<AppWindow, slint::PlatformError> {
    let ui = AppWindow::new()?;
    let ui_handle = ui.as_weak();

    ui.on_request_increase_value(move || {
        let ui = ui_handle.unwrap();
        ui.set_counter(ui.get_counter() + 1);
    });

    Ok(ui)
}

pub fn run() -> Result<(), slint::PlatformError> {
    create()?.run()
}
