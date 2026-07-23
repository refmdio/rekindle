use crate::ClientError;
#[cfg(any(
    all(feature = "web", target_arch = "wasm32"),
    all(feature = "desktop", not(target_arch = "wasm32"))
))]
use crate::{ClientOptions, HandoffFuture};
#[cfg(any(
    all(feature = "web", target_arch = "wasm32"),
    all(feature = "desktop", not(target_arch = "wasm32"))
))]
use core::num::NonZeroU32;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum IntegrationId {
    Gpui,
    Egui,
    Slint,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AdapterTarget {
    Web,
    Desktop,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct AdapterIdentity {
    pub integration: IntegrationId,
    pub target: AdapterTarget,
    pub identity_digest: [u8; 32],
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DesktopShutdown {
    Requested { deadline_ms: u64 },
    ParentDisconnected,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ShutdownRegistration {
    Active,
    Requested,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ShutdownCompletion {
    Acknowledged,
    Disconnected,
}

pub type DesktopShutdownHandler =
    Box<dyn Fn(DesktopShutdown) -> Result<(), ClientError> + Send + Sync + 'static>;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[cfg(all(feature = "web", target_arch = "wasm32"))]
enum WebState {
    Created,
    Preparing,
    Prepared,
    Ready,
    Failed,
}

#[cfg(all(feature = "web", target_arch = "wasm32"))]
pub struct WebSession {
    identity: AdapterIdentity,
    _options: ClientOptions,
    state: WebState,
}

#[cfg(all(feature = "web", target_arch = "wasm32"))]
impl WebSession {
    pub fn new(identity: AdapterIdentity, options: ClientOptions) -> Result<Self, ClientError> {
        validate_identity(identity, AdapterTarget::Web)?;
        Ok(Self {
            identity,
            _options: options,
            state: WebState::Created,
        })
    }

    pub fn prepare(&mut self) -> HandoffFuture<'_, Result<(), ClientError>> {
        if self.state != WebState::Created {
            return Box::pin(async { Err(ClientError::Protocol) });
        }
        self.state = WebState::Preparing;
        Box::pin(async move {
            self.state = WebState::Prepared;
            Ok(())
        })
    }

    pub fn ready(&mut self, _root_count: NonZeroU32) -> Result<(), ClientError> {
        self.require_identity(AdapterTarget::Web)?;
        if self.state != WebState::Prepared {
            return Err(ClientError::Protocol);
        }
        self.state = WebState::Ready;
        Ok(())
    }

    pub fn fail(&mut self, error: &ClientError) -> Result<(), ClientError> {
        self.require_identity(AdapterTarget::Web)?;
        if self.state != WebState::Prepared
            || matches!(error, ClientError::Deadline | ClientError::Shutdown)
        {
            return Err(ClientError::Protocol);
        }
        self.state = WebState::Failed;
        Ok(())
    }

    fn require_identity(&self, target: AdapterTarget) -> Result<(), ClientError> {
        validate_identity(self.identity, target)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[cfg(all(feature = "desktop", not(target_arch = "wasm32")))]
enum DesktopState {
    Created,
    Preparing,
    Prepared,
    Registered,
    Running,
    Failed,
}

#[cfg(all(feature = "desktop", not(target_arch = "wasm32")))]
pub struct DesktopSession {
    identity: AdapterIdentity,
    _options: ClientOptions,
    state: DesktopState,
    shutdown_handler: Option<DesktopShutdownHandler>,
}

#[cfg(all(feature = "desktop", not(target_arch = "wasm32")))]
impl DesktopSession {
    pub fn new(identity: AdapterIdentity, options: ClientOptions) -> Result<Self, ClientError> {
        validate_identity(identity, AdapterTarget::Desktop)?;
        Ok(Self {
            identity,
            _options: options,
            state: DesktopState::Created,
            shutdown_handler: None,
        })
    }

    pub fn prepare(&mut self) -> HandoffFuture<'_, Result<(), ClientError>> {
        if self.state != DesktopState::Created {
            return Box::pin(async { Err(ClientError::Protocol) });
        }
        self.state = DesktopState::Preparing;
        Box::pin(async move {
            self.state = DesktopState::Prepared;
            Ok(())
        })
    }

    pub fn ready(&mut self, _root_count: NonZeroU32) -> Result<(), ClientError> {
        self.require_identity(AdapterTarget::Desktop)?;
        if self.state != DesktopState::Registered {
            return Err(ClientError::Protocol);
        }
        self.state = DesktopState::Running;
        Ok(())
    }

    pub fn fail(&mut self, error: &ClientError) -> Result<(), ClientError> {
        self.require_identity(AdapterTarget::Desktop)?;
        if !matches!(
            self.state,
            DesktopState::Prepared | DesktopState::Registered | DesktopState::Running
        ) || matches!(error, ClientError::Deadline | ClientError::Shutdown)
        {
            return Err(ClientError::Protocol);
        }
        self.state = DesktopState::Failed;
        Ok(())
    }

    pub fn register_shutdown(
        &mut self,
        handler: DesktopShutdownHandler,
    ) -> Result<ShutdownRegistration, ClientError> {
        self.require_identity(AdapterTarget::Desktop)?;
        if self.state != DesktopState::Prepared || self.shutdown_handler.is_some() {
            return Err(ClientError::Protocol);
        }
        self.shutdown_handler = Some(handler);
        self.state = DesktopState::Registered;
        Ok(ShutdownRegistration::Active)
    }

    pub fn complete_shutdown(&mut self) -> Result<ShutdownCompletion, ClientError> {
        Err(ClientError::Protocol)
    }

    fn require_identity(&self, target: AdapterTarget) -> Result<(), ClientError> {
        validate_identity(self.identity, target)
    }
}

#[cfg(any(
    all(feature = "web", target_arch = "wasm32"),
    all(feature = "desktop", not(target_arch = "wasm32"))
))]
fn validate_identity(
    identity: AdapterIdentity,
    expected_target: AdapterTarget,
) -> Result<(), ClientError> {
    if identity.target != expected_target || identity.identity_digest == [0; 32] {
        Err(ClientError::IncompatibleRuntime)
    } else {
        Ok(())
    }
}

#[cfg(all(test, feature = "desktop", not(target_arch = "wasm32")))]
mod tests {
    use super::*;

    fn identity(target: AdapterTarget) -> AdapterIdentity {
        AdapterIdentity {
            integration: IntegrationId::Gpui,
            target,
            identity_digest: [7; 32],
        }
    }

    fn options() -> ClientOptions {
        ClientOptions {
            application_id: "example",
            handoff: None,
        }
    }

    #[test]
    fn desktop_admits_only_a_nonzero_desktop_identity() {
        assert!(DesktopSession::new(identity(AdapterTarget::Desktop), options()).is_ok());
        assert!(matches!(
            DesktopSession::new(identity(AdapterTarget::Web), options()),
            Err(ClientError::IncompatibleRuntime)
        ));

        let mut invalid = identity(AdapterTarget::Desktop);
        invalid.identity_digest = [0; 32];
        assert!(matches!(
            DesktopSession::new(invalid, options()),
            Err(ClientError::IncompatibleRuntime)
        ));
    }

    #[test]
    fn desktop_enforces_prepare_registration_and_ready_order() {
        let mut session =
            DesktopSession::new(identity(AdapterTarget::Desktop), options()).expect("session");
        assert_eq!(session.ready(NonZeroU32::MIN), Err(ClientError::Protocol));
        futures_executor::block_on(session.prepare()).expect("prepare");
        assert!(matches!(
            futures_executor::block_on(session.prepare()),
            Err(ClientError::Protocol)
        ));
        assert_eq!(
            session
                .register_shutdown(Box::new(|_| Ok(())))
                .expect("registration"),
            ShutdownRegistration::Active
        );
        assert_eq!(
            session.register_shutdown(Box::new(|_| Ok(()))),
            Err(ClientError::Protocol)
        );
        session.ready(NonZeroU32::MIN).expect("ready");
        session
            .fail(&ClientError::Application)
            .expect("runtime failure");
        assert_eq!(
            session.fail(&ClientError::Application),
            Err(ClientError::Protocol)
        );
    }

    #[test]
    fn desktop_rejects_control_results_as_adapter_failures() {
        for error in [ClientError::Deadline, ClientError::Shutdown] {
            let mut session =
                DesktopSession::new(identity(AdapterTarget::Desktop), options()).expect("session");
            futures_executor::block_on(session.prepare()).expect("prepare");
            assert_eq!(session.fail(&error), Err(ClientError::Protocol));
        }
    }

    #[test]
    fn shutdown_completion_requires_a_runtime_request() {
        let mut session =
            DesktopSession::new(identity(AdapterTarget::Desktop), options()).expect("session");
        assert_eq!(session.complete_shutdown(), Err(ClientError::Protocol));
    }
}
