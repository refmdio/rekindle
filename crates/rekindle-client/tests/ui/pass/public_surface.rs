use rekindle_client::{
    ClientError, ClientOptions, HandoffError, HandoffFuture, StateHandoff,
};

struct Handoff;

impl StateHandoff for Handoff {
    fn schema_version(&self) -> u32 {
        1
    }

    fn snapshot(&self) -> HandoffFuture<'_, Result<Option<Vec<u8>>, HandoffError>> {
        Box::pin(async { Ok(Some(vec![1])) })
    }

    fn restore<'a>(&'a self, bytes: &'a [u8]) -> HandoffFuture<'a, Result<(), HandoffError>> {
        Box::pin(async move {
            let _ = bytes;
            Ok(())
        })
    }
}

fn assert_send<T: Send>() {}

fn main() {
    static HANDOFF: Handoff = Handoff;
    let options = ClientOptions {
        application_id: "fixture",
        handoff: Some(&HANDOFF),
    };
    assert_send::<HandoffFuture<'static, ()>>();
    let _ = options.application_id;
    let _ = options.handoff.expect("handoff").schema_version();

    let client = ClientError::Io;
    let _ = match client {
        ClientError::IncompatibleRuntime => 0,
        ClientError::PlatformInit => 1,
        ClientError::WindowOpen => 2,
        ClientError::Protocol => 3,
        ClientError::Io => 4,
        ClientError::Deadline => 5,
        _ => 6,
    };

    let handoff = HandoffError::Rejected;
    let _ = match handoff {
        HandoffError::Disabled => 0,
        HandoffError::Rejected => 1,
        HandoffError::InvalidPayload => 2,
        HandoffError::TooLarge => 3,
        HandoffError::Application => 4,
        _ => 5,
    };
}
