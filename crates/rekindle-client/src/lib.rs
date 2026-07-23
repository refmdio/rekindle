#![doc = "Target startup and portable state handoff facade for Rekindle clients."]

use core::fmt;

#[cfg(feature = "state-handoff")]
mod handoff;

#[doc(hidden)]
pub mod adapter_v1;

#[cfg(all(feature = "web", not(target_arch = "wasm32")))]
compile_error!("feature `web` is supported only for target_arch = wasm32");

#[cfg(all(feature = "desktop", target_arch = "wasm32"))]
compile_error!("feature `desktop` is supported only for non-Wasm targets");

#[cfg(all(feature = "web", feature = "desktop"))]
compile_error!("features `web` and `desktop` are mutually exclusive for one target build");

/// Shared target-independent startup options.
pub struct ClientOptions {
    pub application_id: &'static str,
    pub handoff: Option<&'static dyn StateHandoff>,
}

#[cfg(target_arch = "wasm32")]
pub type HandoffFuture<'a, T> = core::pin::Pin<Box<dyn core::future::Future<Output = T> + 'a>>;

#[cfg(not(target_arch = "wasm32"))]
pub type HandoffFuture<'a, T> =
    core::pin::Pin<Box<dyn core::future::Future<Output = T> + Send + 'a>>;

/// Optional application-owned portable state snapshot and restore hooks.
///
/// The same implementation can be installed for Web and desktop builds. The
/// payload is opaque to Rekindle and should contain only application state that
/// the matching schema version can restore.
///
/// ```
/// use rekindle_client::{HandoffError, HandoffFuture, StateHandoff};
///
/// struct EditorState;
///
/// impl StateHandoff for EditorState {
///     fn schema_version(&self) -> u32 { 1 }
///
///     fn snapshot(&self) -> HandoffFuture<'_, Result<Option<Vec<u8>>, HandoffError>> {
///         Box::pin(async { Ok(Some(Vec::new())) })
///     }
///
///     fn restore<'a>(&'a self, bytes: &'a [u8])
///         -> HandoffFuture<'a, Result<(), HandoffError>> {
///         Box::pin(async move { let _ = bytes; Ok(()) })
///     }
/// }
/// ```
pub trait StateHandoff: Send + Sync {
    fn schema_version(&self) -> u32;

    fn snapshot(&self) -> HandoffFuture<'_, Result<Option<Vec<u8>>, HandoffError>>;

    fn restore<'a>(&'a self, bytes: &'a [u8]) -> HandoffFuture<'a, Result<(), HandoffError>>;
}

#[derive(Debug, Clone, PartialEq, Eq)]
#[non_exhaustive]
pub enum ClientError {
    IncompatibleRuntime,
    PlatformInit,
    AdapterGraphics,
    Application,
    WindowOpen,
    Protocol,
    Io,
    Deadline,
    Shutdown,
}

impl fmt::Display for ClientError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::IncompatibleRuntime => "incompatible Rekindle runtime",
            Self::PlatformInit => "platform initialization failed",
            Self::AdapterGraphics => "adapter graphics initialization failed",
            Self::Application => "application startup failed",
            Self::WindowOpen => "application window open failed",
            Self::Protocol => "Rekindle runtime protocol failed",
            Self::Io => "Rekindle runtime I/O failed",
            Self::Deadline => "Rekindle runtime deadline elapsed",
            Self::Shutdown => "Rekindle runtime requested shutdown",
        })
    }
}

impl std::error::Error for ClientError {}

#[derive(Debug, Clone, PartialEq, Eq)]
#[non_exhaustive]
pub enum HandoffError {
    Disabled,
    Rejected,
    InvalidPayload,
    TooLarge,
    Application,
}

impl fmt::Display for HandoffError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::Disabled => "state handoff is disabled",
            Self::Rejected => "state handoff was rejected",
            Self::InvalidPayload => "state handoff payload is invalid",
            Self::TooLarge => "state handoff payload exceeds its limit",
            Self::Application => "application state handoff failed",
        })
    }
}

impl std::error::Error for HandoffError {}

#[cfg(test)]
mod tests {
    use super::*;

    struct Handoff;

    impl StateHandoff for Handoff {
        fn schema_version(&self) -> u32 {
            1
        }

        fn snapshot(&self) -> HandoffFuture<'_, Result<Option<Vec<u8>>, HandoffError>> {
            Box::pin(async { Ok(Some(vec![1, 2, 3])) })
        }

        fn restore<'a>(&'a self, _bytes: &'a [u8]) -> HandoffFuture<'a, Result<(), HandoffError>> {
            Box::pin(async { Ok(()) })
        }
    }

    #[test]
    fn shared_options_accept_the_exact_handoff_trait_object() {
        static HANDOFF: Handoff = Handoff;
        let options = ClientOptions {
            application_id: "example",
            handoff: Some(&HANDOFF),
        };

        assert_eq!(options.application_id, "example");
        assert_eq!(options.handoff.expect("hook").schema_version(), 1);
    }

    #[test]
    fn stable_errors_have_public_messages() {
        assert_eq!(
            ClientError::Protocol.to_string(),
            "Rekindle runtime protocol failed"
        );
        assert_eq!(
            ClientError::AdapterGraphics.to_string(),
            "adapter graphics initialization failed"
        );
        assert_eq!(
            HandoffError::TooLarge.to_string(),
            "state handoff payload exceeds its limit"
        );
    }
}
