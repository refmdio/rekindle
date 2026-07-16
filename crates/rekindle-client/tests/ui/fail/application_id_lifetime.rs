use rekindle_client::ClientOptions;

fn main() {
    let application_id = String::from("fixture");
    let _ = ClientOptions {
        application_id: application_id.as_str(),
        handoff: None,
    };
}
