#![no_main]

#[wasm_bindgen::prelude::wasm_bindgen(start)]
pub fn start() {
    client::run().expect("failed to run the application");
}
