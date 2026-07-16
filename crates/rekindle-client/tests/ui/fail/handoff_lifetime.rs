use rekindle_client::{ClientOptions, HandoffError, HandoffFuture, StateHandoff};

struct Handoff;

impl StateHandoff for Handoff {
    fn schema_version(&self) -> u32 {
        1
    }

    fn snapshot(&self) -> HandoffFuture<'_, Result<Option<Vec<u8>>, HandoffError>> {
        Box::pin(async { Ok(None) })
    }

    fn restore<'a>(&'a self, _bytes: &'a [u8]) -> HandoffFuture<'a, Result<(), HandoffError>> {
        Box::pin(async { Ok(()) })
    }
}

fn main() {
    let handoff = Handoff;
    let _ = ClientOptions {
        application_id: "fixture",
        handoff: Some(&handoff),
    };
}
