#![allow(dead_code)]

use crate::{HandoffError, HandoffFuture, StateHandoff};
use futures_util::FutureExt;
use sha2::{Digest, Sha256};
use std::{future::poll_fn, panic::AssertUnwindSafe, task::Poll};

pub(crate) const PROTOCOL_VERSION: u8 = 1;
pub(crate) const MAX_PAYLOAD_BYTES: usize = 16 * 1024 * 1024;
pub(crate) const MIN_DEADLINE_MS: u64 = 100;
pub(crate) const MAX_DEADLINE_MS: u64 = 10_000;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum Target {
    Web,
    Desktop,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct Policy {
    pub(crate) max_bytes: usize,
    pub(crate) snapshot_deadline_ms: u64,
    pub(crate) restore_deadline_ms: u64,
}

impl Policy {
    pub(crate) fn new(
        max_bytes: usize,
        snapshot_deadline_ms: u64,
        restore_deadline_ms: u64,
    ) -> Result<Self, Failure> {
        if max_bytes <= MAX_PAYLOAD_BYTES
            && (MIN_DEADLINE_MS..=MAX_DEADLINE_MS).contains(&snapshot_deadline_ms)
            && (MIN_DEADLINE_MS..=MAX_DEADLINE_MS).contains(&restore_deadline_ms)
        {
            Ok(Self {
                max_bytes,
                snapshot_deadline_ms,
                restore_deadline_ms,
            })
        } else {
            Err(Failure::InvalidPayload)
        }
    }

    pub(crate) fn enabled(self) -> bool {
        self.max_bytes > 0
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct Envelope {
    pub(crate) version: u8,
    pub(crate) application_id: String,
    pub(crate) schema_version: u32,
    pub(crate) source_target: Target,
    pub(crate) source_artifact_id: [u8; 32],
    pub(crate) destination_artifact_id: [u8; 32],
    pub(crate) created_at_unix_ms: u64,
    pub(crate) expires_at_unix_ms: u64,
    pub(crate) payload_sha256: [u8; 32],
    pub(crate) payload: Vec<u8>,
}

impl Envelope {
    pub(crate) fn payload_len(&self) -> usize {
        self.payload.len()
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct SnapshotRequest<'a> {
    pub(crate) application_id: &'a str,
    pub(crate) source_target: Target,
    pub(crate) source_artifact_id: [u8; 32],
    pub(crate) destination_artifact_id: [u8; 32],
    pub(crate) created_at_unix_ms: u64,
    pub(crate) expires_at_unix_ms: u64,
    pub(crate) policy: Policy,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct RestoreRequest<'a> {
    pub(crate) application_id: &'a str,
    pub(crate) schema_version: u32,
    pub(crate) target: Target,
    pub(crate) source_artifact_id: [u8; 32],
    pub(crate) destination_artifact_id: [u8; 32],
    pub(crate) now_unix_ms: u64,
    pub(crate) policy: Policy,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum Failure {
    Disabled,
    Rejected,
    InvalidPayload,
    TooLarge,
    Application,
    Deadline,
    Cancelled,
    Panicked,
    Incompatible,
}

impl From<HandoffError> for Failure {
    fn from(error: HandoffError) -> Self {
        match error {
            HandoffError::Disabled => Self::Disabled,
            HandoffError::Rejected => Self::Rejected,
            HandoffError::InvalidPayload => Self::InvalidPayload,
            HandoffError::TooLarge => Self::TooLarge,
            HandoffError::Application => Self::Application,
        }
    }
}

#[derive(Debug)]
pub(crate) enum AdapterResult<T> {
    Completed(T),
    Deadline,
    Cancelled,
}

#[cfg(target_arch = "wasm32")]
pub(crate) trait AdapterBounds {}

#[cfg(target_arch = "wasm32")]
impl<T: ?Sized> AdapterBounds for T {}

#[cfg(not(target_arch = "wasm32"))]
pub(crate) trait AdapterBounds: Send + Sync {}

#[cfg(not(target_arch = "wasm32"))]
impl<T: Send + Sync + ?Sized> AdapterBounds for T {}

pub(crate) trait Adapter: AdapterBounds {
    fn deadline(&self, milliseconds: u64) -> HandoffFuture<'_, ()>;

    fn cancelled(&self) -> HandoffFuture<'_, ()>;
}

pub(crate) fn settle<T>(result: AdapterResult<T>) -> Result<T, Failure> {
    match result {
        AdapterResult::Completed(value) => Ok(value),
        AdapterResult::Deadline => Err(Failure::Deadline),
        AdapterResult::Cancelled => Err(Failure::Cancelled),
    }
}

async fn bounded<'a, T>(
    adapter: &'a dyn Adapter,
    operation: HandoffFuture<'a, T>,
    deadline_ms: u64,
) -> Result<T, Failure> {
    let mut operation = operation;
    let mut deadline = adapter.deadline(deadline_ms);
    let mut cancellation = adapter.cancelled();

    let result = poll_fn(move |context| {
        if cancellation.as_mut().poll(context).is_ready() {
            return Poll::Ready(AdapterResult::Cancelled);
        }

        if deadline.as_mut().poll(context).is_ready() {
            return Poll::Ready(AdapterResult::Deadline);
        }

        operation
            .as_mut()
            .poll(context)
            .map(AdapterResult::Completed)
    })
    .await;

    settle(result)
}

pub(crate) fn snapshot<'a>(
    adapter: &'a dyn Adapter,
    hook: Option<&'a dyn StateHandoff>,
    request: SnapshotRequest<'a>,
) -> HandoffFuture<'a, Result<Option<Envelope>, Failure>> {
    Box::pin(async move {
        let Some(hook) = hook else {
            return Ok(None);
        };

        if !request.policy.enabled() {
            return Ok(None);
        }

        validate_snapshot_request(&request)?;
        let schema_version = std::panic::catch_unwind(AssertUnwindSafe(|| hook.schema_version()))
            .map_err(|_| Failure::Panicked)?;
        let future = std::panic::catch_unwind(AssertUnwindSafe(|| hook.snapshot()))
            .map_err(|_| Failure::Panicked)?;
        let application = Box::pin(async move {
            AssertUnwindSafe(future)
                .catch_unwind()
                .await
                .map_err(|_| Failure::Panicked)?
                .map_err(Failure::from)
        });

        let bytes = bounded(adapter, application, request.policy.snapshot_deadline_ms).await??;

        let Some(payload) = bytes else {
            return Ok(None);
        };

        if payload.len() > request.policy.max_bytes {
            return Err(Failure::TooLarge);
        }

        let payload_sha256 = digest(&payload);

        Ok(Some(Envelope {
            version: PROTOCOL_VERSION,
            application_id: request.application_id.to_owned(),
            schema_version,
            source_target: request.source_target,
            source_artifact_id: request.source_artifact_id,
            destination_artifact_id: request.destination_artifact_id,
            created_at_unix_ms: request.created_at_unix_ms,
            expires_at_unix_ms: request.expires_at_unix_ms,
            payload_sha256,
            payload,
        }))
    })
}

pub(crate) fn restore<'a>(
    adapter: &'a dyn Adapter,
    hook: Option<&'a dyn StateHandoff>,
    envelope: Option<&'a Envelope>,
    request: RestoreRequest<'a>,
) -> HandoffFuture<'a, Result<bool, Failure>> {
    Box::pin(async move {
        let (Some(hook), Some(envelope)) = (hook, envelope) else {
            return Ok(false);
        };

        if !request.policy.enabled() {
            return Ok(false);
        }

        let schema_version = std::panic::catch_unwind(AssertUnwindSafe(|| hook.schema_version()))
            .map_err(|_| Failure::Panicked)?;
        if schema_version != request.schema_version {
            return Err(Failure::Incompatible);
        }

        validate_envelope(envelope, &request)?;
        let future = std::panic::catch_unwind(AssertUnwindSafe(|| {
            hook.restore(envelope.payload.as_slice())
        }))
        .map_err(|_| Failure::Panicked)?;

        let application = Box::pin(async move {
            AssertUnwindSafe(future)
                .catch_unwind()
                .await
                .map_err(|_| Failure::Panicked)?
                .map_err(Failure::from)
        });

        bounded(adapter, application, request.policy.restore_deadline_ms).await??;

        Ok(true)
    })
}

fn validate_snapshot_request(request: &SnapshotRequest<'_>) -> Result<(), Failure> {
    if request.application_id.is_empty()
        || request.expires_at_unix_ms <= request.created_at_unix_ms
        || request.source_artifact_id == [0; 32]
        || request.destination_artifact_id == [0; 32]
    {
        Err(Failure::InvalidPayload)
    } else {
        Ok(())
    }
}

fn validate_envelope(envelope: &Envelope, request: &RestoreRequest<'_>) -> Result<(), Failure> {
    if envelope.version != PROTOCOL_VERSION
        || envelope.application_id != request.application_id
        || envelope.schema_version != request.schema_version
        || envelope.source_target != request.target
        || envelope.source_artifact_id != request.source_artifact_id
        || envelope.destination_artifact_id != request.destination_artifact_id
    {
        return Err(Failure::Incompatible);
    }

    if request.now_unix_ms < envelope.created_at_unix_ms
        || request.now_unix_ms >= envelope.expires_at_unix_ms
        || envelope.created_at_unix_ms >= envelope.expires_at_unix_ms
    {
        return Err(Failure::InvalidPayload);
    }

    if envelope.payload_len() > request.policy.max_bytes {
        return Err(Failure::TooLarge);
    }

    if digest(&envelope.payload) != envelope.payload_sha256 {
        return Err(Failure::InvalidPayload);
    }

    Ok(())
}

fn digest(bytes: &[u8]) -> [u8; 32] {
    Sha256::digest(bytes).into()
}

#[cfg(test)]
mod tests {
    use super::*;
    use futures_executor::block_on;
    use std::{
        future::{Future, pending},
        marker::PhantomData,
        pin::Pin,
        sync::{
            Arc, Mutex,
            atomic::{AtomicBool, AtomicUsize, Ordering},
        },
        task::{Context, Wake, Waker},
    };

    struct PassiveAdapter;

    impl Adapter for PassiveAdapter {
        fn deadline(&self, _milliseconds: u64) -> HandoffFuture<'_, ()> {
            Box::pin(pending())
        }

        fn cancelled(&self) -> HandoffFuture<'_, ()> {
            Box::pin(pending())
        }
    }

    static PASSIVE_ADAPTER: PassiveAdapter = PassiveAdapter;

    fn snapshot<'a>(
        hook: Option<&'a dyn StateHandoff>,
        request: SnapshotRequest<'a>,
    ) -> HandoffFuture<'a, Result<Option<Envelope>, Failure>> {
        super::snapshot(&PASSIVE_ADAPTER, hook, request)
    }

    fn restore<'a>(
        hook: Option<&'a dyn StateHandoff>,
        envelope: Option<&'a Envelope>,
        request: RestoreRequest<'a>,
    ) -> HandoffFuture<'a, Result<bool, Failure>> {
        super::restore(&PASSIVE_ADAPTER, hook, envelope, request)
    }

    #[derive(Clone, Default)]
    struct Signal {
        ready: Arc<AtomicBool>,
        waker: Arc<Mutex<Option<Waker>>>,
    }

    impl Signal {
        fn fire(&self) {
            self.ready.store(true, Ordering::Release);

            if let Some(waker) = self.waker.lock().expect("signal waker lock").take() {
                waker.wake();
            }
        }

        fn wait(&self) -> SignalFuture {
            SignalFuture(self.clone())
        }
    }

    struct SignalFuture(Signal);

    impl Future for SignalFuture {
        type Output = ();

        fn poll(self: Pin<&mut Self>, context: &mut Context<'_>) -> Poll<Self::Output> {
            if self.0.ready.load(Ordering::Acquire) {
                Poll::Ready(())
            } else {
                *self.0.waker.lock().expect("signal waker lock") = Some(context.waker().clone());

                if self.0.ready.load(Ordering::Acquire) {
                    Poll::Ready(())
                } else {
                    Poll::Pending
                }
            }
        }
    }

    #[derive(Default)]
    struct ControlledAdapter {
        deadline: Signal,
        cancellation: Signal,
        requested_deadlines: Mutex<Vec<u64>>,
    }

    impl Adapter for ControlledAdapter {
        fn deadline(&self, milliseconds: u64) -> HandoffFuture<'_, ()> {
            self.requested_deadlines
                .lock()
                .expect("deadline request lock")
                .push(milliseconds);
            Box::pin(self.deadline.wait())
        }

        fn cancelled(&self) -> HandoffFuture<'_, ()> {
            Box::pin(self.cancellation.wait())
        }
    }

    struct PendingOperation<T> {
        drops: Arc<AtomicUsize>,
        output: PhantomData<fn() -> T>,
    }

    impl<T> PendingOperation<T> {
        fn new(drops: Arc<AtomicUsize>) -> Self {
            Self {
                drops,
                output: PhantomData,
            }
        }
    }

    impl<T> Future for PendingOperation<T> {
        type Output = T;

        fn poll(self: Pin<&mut Self>, _context: &mut Context<'_>) -> Poll<Self::Output> {
            Poll::Pending
        }
    }

    impl<T> Drop for PendingOperation<T> {
        fn drop(&mut self) {
            self.drops.fetch_add(1, Ordering::Relaxed);
        }
    }

    struct NoopWake;

    impl Wake for NoopWake {
        fn wake(self: Arc<Self>) {}
    }

    fn poll_once<T>(future: &mut HandoffFuture<'_, T>) -> Poll<T> {
        let waker = Waker::from(Arc::new(NoopWake));
        let mut context = Context::from_waker(&waker);
        future.as_mut().poll(&mut context)
    }

    struct Hook {
        schema: u32,
        payload: Option<Vec<u8>>,
        snapshot_error: Option<HandoffError>,
        restore_error: Option<HandoffError>,
        panic_schema: bool,
        panic_snapshot: bool,
        panic_restore: bool,
        calls: Arc<AtomicUsize>,
    }

    impl StateHandoff for Hook {
        fn schema_version(&self) -> u32 {
            assert!(!self.panic_schema, "schema panic must remain private");
            self.schema
        }

        fn snapshot(&self) -> HandoffFuture<'_, Result<Option<Vec<u8>>, HandoffError>> {
            assert!(!self.panic_snapshot, "snapshot panic must remain private");
            Box::pin(async move {
                self.calls.fetch_add(1, Ordering::Relaxed);
                match &self.snapshot_error {
                    Some(error) => Err(error.clone()),
                    None => Ok(self.payload.clone()),
                }
            })
        }

        fn restore<'a>(&'a self, _bytes: &'a [u8]) -> HandoffFuture<'a, Result<(), HandoffError>> {
            Box::pin(async move {
                self.calls.fetch_add(1, Ordering::Relaxed);
                assert!(!self.panic_restore, "restore panic must remain private");
                match &self.restore_error {
                    Some(error) => Err(error.clone()),
                    None => Ok(()),
                }
            })
        }
    }

    struct PendingHook {
        snapshot_drops: Arc<AtomicUsize>,
        restore_drops: Arc<AtomicUsize>,
    }

    impl StateHandoff for PendingHook {
        fn schema_version(&self) -> u32 {
            7
        }

        fn snapshot(&self) -> HandoffFuture<'_, Result<Option<Vec<u8>>, HandoffError>> {
            Box::pin(PendingOperation::new(self.snapshot_drops.clone()))
        }

        fn restore<'a>(&'a self, _bytes: &'a [u8]) -> HandoffFuture<'a, Result<(), HandoffError>> {
            Box::pin(PendingOperation::new(self.restore_drops.clone()))
        }
    }

    struct YieldOnce<T> {
        value: Option<T>,
        yielded: bool,
    }

    impl<T> YieldOnce<T> {
        fn new(value: T) -> Self {
            Self {
                value: Some(value),
                yielded: false,
            }
        }
    }

    impl<T: Unpin> Future for YieldOnce<T> {
        type Output = T;

        fn poll(mut self: Pin<&mut Self>, context: &mut Context<'_>) -> Poll<Self::Output> {
            if self.yielded {
                Poll::Ready(self.value.take().expect("yielding future output"))
            } else {
                self.yielded = true;
                context.waker().wake_by_ref();
                Poll::Pending
            }
        }
    }

    struct YieldingHook;

    impl StateHandoff for YieldingHook {
        fn schema_version(&self) -> u32 {
            7
        }

        fn snapshot(&self) -> HandoffFuture<'_, Result<Option<Vec<u8>>, HandoffError>> {
            Box::pin(YieldOnce::new(Ok(Some(vec![4, 2]))))
        }

        fn restore<'a>(&'a self, _bytes: &'a [u8]) -> HandoffFuture<'a, Result<(), HandoffError>> {
            Box::pin(YieldOnce::new(Ok(())))
        }
    }

    fn hook(payload: Option<Vec<u8>>) -> Hook {
        Hook {
            schema: 7,
            payload,
            snapshot_error: None,
            restore_error: None,
            panic_schema: false,
            panic_snapshot: false,
            panic_restore: false,
            calls: Arc::new(AtomicUsize::new(0)),
        }
    }

    fn policy(max_bytes: usize) -> Policy {
        Policy::new(max_bytes, 1_000, 1_000).expect("valid policy")
    }

    fn snapshot_request(max_bytes: usize) -> SnapshotRequest<'static> {
        SnapshotRequest {
            application_id: "editor",
            source_target: Target::Web,
            source_artifact_id: [1; 32],
            destination_artifact_id: [2; 32],
            created_at_unix_ms: 10_000,
            expires_at_unix_ms: 40_000,
            policy: policy(max_bytes),
        }
    }

    fn restore_request(max_bytes: usize) -> RestoreRequest<'static> {
        RestoreRequest {
            application_id: "editor",
            schema_version: 7,
            target: Target::Web,
            source_artifact_id: [1; 32],
            destination_artifact_id: [2; 32],
            now_unix_ms: 20_000,
            policy: policy(max_bytes),
        }
    }

    fn envelope(payload: Vec<u8>) -> Envelope {
        let hook = hook(Some(payload));
        block_on(snapshot(Some(&hook), snapshot_request(MAX_PAYLOAD_BYTES)))
            .expect("snapshot")
            .expect("payload")
    }

    #[test]
    fn missing_hook_and_zero_limit_are_disabled_without_invocation() {
        assert_eq!(block_on(snapshot(None, snapshot_request(16))), Ok(None));

        let hook = hook(Some(vec![1]));
        assert_eq!(
            block_on(snapshot(Some(&hook), snapshot_request(0))),
            Ok(None)
        );
        assert_eq!(hook.calls.load(Ordering::Relaxed), 0);
    }

    #[test]
    fn snapshot_accepts_empty_and_exact_limit_payloads() {
        let empty = envelope(Vec::new());
        assert_eq!(empty.payload_len(), 0);
        assert_eq!(empty.payload_sha256, digest(&[]));

        let exact_hook = hook(Some(vec![5; 8]));
        let exact = block_on(snapshot(Some(&exact_hook), snapshot_request(8)))
            .expect("snapshot")
            .expect("payload");
        assert_eq!(exact.payload_len(), 8);

        let oversized = hook(Some(vec![5; 9]));
        assert_eq!(
            block_on(snapshot(Some(&oversized), snapshot_request(8))),
            Err(Failure::TooLarge)
        );
    }

    #[test]
    fn restore_checks_every_compatibility_and_integrity_boundary() {
        let compatible_hook = hook(None);
        let valid = envelope(vec![1, 2, 3]);
        assert_eq!(
            block_on(restore(
                Some(&compatible_hook),
                Some(&valid),
                restore_request(3)
            )),
            Ok(true)
        );

        for invalid in [
            Envelope {
                version: 2,
                ..valid.clone()
            },
            Envelope {
                application_id: "other".into(),
                ..valid.clone()
            },
            Envelope {
                schema_version: 8,
                ..valid.clone()
            },
            Envelope {
                source_target: Target::Desktop,
                ..valid.clone()
            },
            Envelope {
                source_artifact_id: [3; 32],
                ..valid.clone()
            },
            Envelope {
                destination_artifact_id: [3; 32],
                ..valid.clone()
            },
        ] {
            assert_eq!(
                block_on(restore(
                    Some(&compatible_hook),
                    Some(&invalid),
                    restore_request(3)
                )),
                Err(Failure::Incompatible)
            );
        }

        let incompatible_hook = Hook {
            schema: 8,
            ..hook(None)
        };
        assert_eq!(
            block_on(restore(
                Some(&incompatible_hook),
                Some(&valid),
                restore_request(3)
            )),
            Err(Failure::Incompatible)
        );

        let mut corrupt = valid.clone();
        corrupt.payload[0] ^= 0xff;
        assert_eq!(
            block_on(restore(
                Some(&compatible_hook),
                Some(&corrupt),
                restore_request(3)
            )),
            Err(Failure::InvalidPayload)
        );

        let expired = RestoreRequest {
            now_unix_ms: valid.expires_at_unix_ms,
            ..restore_request(3)
        };
        assert_eq!(
            block_on(restore(Some(&compatible_hook), Some(&valid), expired)),
            Err(Failure::InvalidPayload)
        );
    }

    #[test]
    fn restore_skips_missing_state_and_rejects_payload_above_current_limit() {
        let hook = hook(None);
        assert_eq!(block_on(restore(None, None, restore_request(8))), Ok(false));
        let valid = envelope(vec![1, 2, 3]);
        assert_eq!(
            block_on(restore(Some(&hook), Some(&valid), restore_request(2))),
            Err(Failure::TooLarge)
        );
    }

    #[test]
    fn application_errors_and_panics_are_contained() {
        let mut failing = hook(Some(vec![1]));
        failing.snapshot_error = Some(HandoffError::Rejected);
        assert_eq!(
            block_on(snapshot(Some(&failing), snapshot_request(8))),
            Err(Failure::Rejected)
        );

        failing.snapshot_error = None;
        failing.panic_schema = true;
        assert_eq!(
            block_on(snapshot(Some(&failing), snapshot_request(8))),
            Err(Failure::Panicked)
        );

        failing.panic_schema = false;
        failing.panic_snapshot = true;
        assert_eq!(
            block_on(snapshot(Some(&failing), snapshot_request(8))),
            Err(Failure::Panicked)
        );

        let valid = envelope(vec![1]);
        failing.panic_snapshot = false;
        failing.panic_restore = true;
        assert_eq!(
            block_on(restore(Some(&failing), Some(&valid), restore_request(8))),
            Err(Failure::Panicked)
        );
    }

    #[test]
    fn pending_snapshot_honors_its_deadline_and_drops_the_hook_future() {
        let adapter = ControlledAdapter::default();
        let snapshot_drops = Arc::new(AtomicUsize::new(0));
        let hook = PendingHook {
            snapshot_drops: snapshot_drops.clone(),
            restore_drops: Arc::new(AtomicUsize::new(0)),
        };
        let mut request = snapshot_request(8);
        request.policy.snapshot_deadline_ms = 321;
        let mut future = super::snapshot(&adapter, Some(&hook), request);

        assert!(poll_once(&mut future).is_pending());
        assert_eq!(
            *adapter
                .requested_deadlines
                .lock()
                .expect("deadline request lock"),
            vec![321]
        );

        adapter.deadline.fire();
        assert_eq!(poll_once(&mut future), Poll::Ready(Err(Failure::Deadline)));
        assert_eq!(snapshot_drops.load(Ordering::Relaxed), 1);
    }

    #[test]
    fn pending_restore_honors_cancellation_and_drops_the_hook_future() {
        let adapter = ControlledAdapter::default();
        let restore_drops = Arc::new(AtomicUsize::new(0));
        let hook = PendingHook {
            snapshot_drops: Arc::new(AtomicUsize::new(0)),
            restore_drops: restore_drops.clone(),
        };
        let envelope = envelope(vec![1, 2, 3]);
        let mut request = restore_request(3);
        request.policy.restore_deadline_ms = 654;
        let mut future = super::restore(&adapter, Some(&hook), Some(&envelope), request);

        assert!(poll_once(&mut future).is_pending());
        assert_eq!(
            *adapter
                .requested_deadlines
                .lock()
                .expect("deadline request lock"),
            vec![654]
        );

        adapter.cancellation.fire();
        assert_eq!(poll_once(&mut future), Poll::Ready(Err(Failure::Cancelled)));
        assert_eq!(restore_drops.load(Ordering::Relaxed), 1);
    }

    #[test]
    fn snapshot_cancellation_and_restore_deadline_use_the_same_bounded_contract() {
        let snapshot_adapter = ControlledAdapter::default();
        let snapshot_drops = Arc::new(AtomicUsize::new(0));
        let snapshot_hook = PendingHook {
            snapshot_drops: snapshot_drops.clone(),
            restore_drops: Arc::new(AtomicUsize::new(0)),
        };
        let mut snapshot =
            super::snapshot(&snapshot_adapter, Some(&snapshot_hook), snapshot_request(8));

        assert!(poll_once(&mut snapshot).is_pending());
        snapshot_adapter.cancellation.fire();
        assert_eq!(
            poll_once(&mut snapshot),
            Poll::Ready(Err(Failure::Cancelled))
        );
        assert_eq!(snapshot_drops.load(Ordering::Relaxed), 1);

        let restore_adapter = ControlledAdapter::default();
        let restore_drops = Arc::new(AtomicUsize::new(0));
        let restore_hook = PendingHook {
            snapshot_drops: Arc::new(AtomicUsize::new(0)),
            restore_drops: restore_drops.clone(),
        };
        let envelope = envelope(vec![1, 2, 3]);
        let mut restore = super::restore(
            &restore_adapter,
            Some(&restore_hook),
            Some(&envelope),
            restore_request(3),
        );

        assert!(poll_once(&mut restore).is_pending());
        restore_adapter.deadline.fire();
        assert_eq!(poll_once(&mut restore), Poll::Ready(Err(Failure::Deadline)));
        assert_eq!(restore_drops.load(Ordering::Relaxed), 1);
    }

    #[test]
    fn yielding_snapshot_and_restore_complete_before_pending_bounds() {
        let adapter = ControlledAdapter::default();
        let snapshot = block_on(super::snapshot(
            &adapter,
            Some(&YieldingHook),
            snapshot_request(8),
        ))
        .expect("yielding snapshot")
        .expect("yielding payload");

        assert_eq!(snapshot.payload, vec![4, 2]);
        assert_eq!(
            block_on(super::restore(
                &adapter,
                Some(&YieldingHook),
                Some(&snapshot),
                restore_request(8),
            )),
            Ok(true)
        );
    }

    #[test]
    fn exact_deadline_precedes_an_operation_that_becomes_ready_on_the_same_poll() {
        let adapter = ControlledAdapter::default();
        let mut future = super::snapshot(
            &adapter,
            Some(&YieldingHook),
            snapshot_request(MAX_PAYLOAD_BYTES),
        );

        assert!(poll_once(&mut future).is_pending());
        adapter.deadline.fire();
        assert_eq!(poll_once(&mut future), Poll::Ready(Err(Failure::Deadline)));
    }

    #[test]
    fn cancellation_precedes_deadline_when_both_are_observed_together() {
        let adapter = ControlledAdapter::default();
        let hook = PendingHook {
            snapshot_drops: Arc::new(AtomicUsize::new(0)),
            restore_drops: Arc::new(AtomicUsize::new(0)),
        };
        let mut future = super::snapshot(&adapter, Some(&hook), snapshot_request(8));

        assert!(poll_once(&mut future).is_pending());
        adapter.deadline.fire();
        adapter.cancellation.fire();
        assert_eq!(poll_once(&mut future), Poll::Ready(Err(Failure::Cancelled)));
    }

    #[cfg(not(target_arch = "wasm32"))]
    #[test]
    fn native_bounded_handoff_future_remains_send() {
        fn assert_send<T: Send>(_value: T) {}

        let adapter = ControlledAdapter::default();
        let hook = hook(Some(vec![1]));
        assert_send(super::snapshot(&adapter, Some(&hook), snapshot_request(8)));
    }

    #[cfg(target_arch = "wasm32")]
    #[test]
    fn web_adapter_and_bounded_future_may_remain_local() {
        use std::{cell::Cell, rc::Rc};

        struct LocalAdapter(Rc<Cell<u64>>);

        impl Adapter for LocalAdapter {
            fn deadline(&self, milliseconds: u64) -> HandoffFuture<'_, ()> {
                self.0.set(milliseconds);
                Box::pin(pending())
            }

            fn cancelled(&self) -> HandoffFuture<'_, ()> {
                Box::pin(pending())
            }
        }

        let adapter = LocalAdapter(Rc::new(Cell::new(0)));
        let hook = hook(Some(vec![1]));
        let mut future = super::snapshot(&adapter, Some(&hook), snapshot_request(8));

        assert!(poll_once(&mut future).is_ready());
        assert_eq!(adapter.0.get(), 1_000);
    }

    #[test]
    fn portable_semantics_accept_both_targets() {
        let hook = hook(Some(vec![9]));
        let snapshot_request = SnapshotRequest {
            source_target: Target::Desktop,
            ..snapshot_request(1)
        };
        let envelope = block_on(snapshot(Some(&hook), snapshot_request))
            .expect("snapshot")
            .expect("payload");
        let restore_request = RestoreRequest {
            target: Target::Desktop,
            ..restore_request(1)
        };

        assert_eq!(
            block_on(restore(Some(&hook), Some(&envelope), restore_request)),
            Ok(true)
        );
    }

    #[test]
    fn hook_errors_preserve_their_stable_category() {
        for (error, expected) in [
            (HandoffError::Disabled, Failure::Disabled),
            (HandoffError::Rejected, Failure::Rejected),
            (HandoffError::InvalidPayload, Failure::InvalidPayload),
            (HandoffError::TooLarge, Failure::TooLarge),
            (HandoffError::Application, Failure::Application),
        ] {
            assert_eq!(Failure::from(error), expected);
        }
    }

    #[test]
    fn policy_rejects_out_of_range_budgets() {
        assert_eq!(
            Policy::new(MAX_PAYLOAD_BYTES + 1, 1_000, 1_000),
            Err(Failure::InvalidPayload)
        );
        assert_eq!(Policy::new(1, 99, 1_000), Err(Failure::InvalidPayload));
        assert_eq!(Policy::new(1, 1_000, 10_001), Err(Failure::InvalidPayload));
    }
}
