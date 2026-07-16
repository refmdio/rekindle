use rekindle_client::{HandoffError, HandoffFuture, StateHandoff};

struct Handoff;

impl StateHandoff for Handoff {
    fn schema_version(&self) -> u32 {
        1
    }

    fn snapshot(&self) -> Result<Option<Vec<u8>>, HandoffError> {
        Ok(None)
    }

    fn restore<'a>(&'a self, _bytes: &'a [u8]) -> HandoffFuture<'a, Result<(), HandoffError>> {
        Box::pin(async { Ok(()) })
    }
}

fn main() {}
