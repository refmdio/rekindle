use rekindle_client::{HandoffError, HandoffFuture, StateHandoff};
use std::rc::Rc;

struct Handoff(Rc<()>);

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

fn main() {}
