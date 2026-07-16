use rekindle_client::ClientError;

fn classify(error: ClientError) -> u8 {
    match error {
        ClientError::IncompatibleRuntime => 0,
        ClientError::PlatformInit => 1,
        ClientError::WindowOpen => 2,
        ClientError::Protocol => 3,
        ClientError::Io => 4,
        ClientError::Deadline => 5,
    }
}

fn main() {
    let _ = classify(ClientError::Io);
}
