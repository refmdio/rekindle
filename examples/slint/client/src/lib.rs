use slint::ComponentHandle;

slint::include_modules!();

pub fn create() -> Result<AppWindow, slint::PlatformError> {
    let ui = AppWindow::new()?;
    let handle = ui.as_weak();

    ui.on_increment(move || {
        let ui = handle.unwrap();
        ui.set_count(ui.get_count() + 1);
    });

    Ok(ui)
}

pub fn run() -> Result<(), slint::PlatformError> {
    create()?.run()
}
