use rekindle_client::{HandoffError, HandoffFuture, StateHandoff};
use std::rc::Rc;

struct Handoff;

impl StateHandoff for Handoff {
    fn schema_version(&self) -> u32 {
        1
    }

    fn snapshot(&self) -> HandoffFuture<'_, Result<Option<Vec<u8>>, HandoffError>> {
        Box::pin(async {
            let value = Rc::new(());
            std::future::pending::<()>().await;
            drop(value);
            Ok(None)
        })
    }

    fn restore<'a>(&'a self, _bytes: &'a [u8]) -> HandoffFuture<'a, Result<(), HandoffError>> {
        Box::pin(async { Ok(()) })
    }
}

fn main() {}
