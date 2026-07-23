use rekindle_client::{
    adapter_v1::{AdapterIdentity, AdapterTarget, IntegrationId},
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
    let identity = AdapterIdentity {
        integration: IntegrationId::Gpui,
        target: AdapterTarget::Web,
        identity_digest: [1; 32],
    };
    let _ = (identity, IntegrationId::Egui, IntegrationId::Slint, AdapterTarget::Desktop);

    let client = ClientError::Io;
    let _ = match client {
        ClientError::IncompatibleRuntime => 0,
        ClientError::PlatformInit => 1,
        ClientError::AdapterGraphics => 2,
        ClientError::Application => 3,
        ClientError::WindowOpen => 4,
        ClientError::Protocol => 5,
        ClientError::Io => 6,
        ClientError::Deadline => 7,
        ClientError::Shutdown => 8,
        _ => 9,
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
