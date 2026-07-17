#![allow(dead_code)]

use crate::{HandoffError, HandoffFuture, StateHandoff};
use futures_util::FutureExt;
use sha2::{Digest, Sha256};
use std::panic::AssertUnwindSafe;

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

pub(crate) fn settle<T>(result: AdapterResult<T>) -> Result<T, Failure> {
    match result {
        AdapterResult::Completed(value) => Ok(value),
        AdapterResult::Deadline => Err(Failure::Deadline),
        AdapterResult::Cancelled => Err(Failure::Cancelled),
    }
}

pub(crate) fn snapshot<'a>(
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
        let bytes = AssertUnwindSafe(future)
            .catch_unwind()
            .await
            .map_err(|_| Failure::Panicked)?
            .map_err(Failure::from)?;

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

        AssertUnwindSafe(future)
            .catch_unwind()
            .await
            .map_err(|_| Failure::Panicked)?
            .map_err(Failure::from)?;

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
    use std::sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    };

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
    fn adapter_contract_preserves_deadline_and_cancellation() {
        assert_eq!(
            settle::<()>(AdapterResult::Deadline),
            Err(Failure::Deadline)
        );
        assert_eq!(
            settle::<()>(AdapterResult::Cancelled),
            Err(Failure::Cancelled)
        );
        assert_eq!(settle(AdapterResult::Completed(7)), Ok(7));
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
