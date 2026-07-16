use rekindle_client::ClientOptions;

fn main() {
    let _ = ClientOptions {
        application_id: "fixture",
        handoff: None,
        extra: (),
    };
}
