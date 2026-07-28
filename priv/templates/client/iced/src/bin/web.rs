#![no_main]

#[wasm_bindgen::prelude::wasm_bindgen(start)]
pub fn start() {
    client::run().expect("failed to start the application");
}
