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

#[cfg(test)]
mod tests {
    #[test]
    fn increments_the_counter() {
        i_slint_backend_testing::init_no_event_loop();

        let app = super::create().expect("application should initialize");

        assert_eq!(app.get_count(), 0);
        app.invoke_increment();
        assert_eq!(app.get_count(), 1);
    }
}
