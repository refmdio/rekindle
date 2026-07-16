use std::env;
use std::ffi::OsStr;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::time::{SystemTime, UNIX_EPOCH};

struct Harness {
    root: PathBuf,
    deps: PathBuf,
    library: PathBuf,
    rustc: PathBuf,
    wasm_rustc: PathBuf,
}

impl Harness {
    fn new() -> Self {
        let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("Cargo.toml");
        let root = env::temp_dir().join(format!(
            "rekindle-client-compile-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .expect("system time after epoch")
                .as_nanos()
        ));

        let output = Command::new(env::var_os("CARGO").unwrap_or_else(|| "cargo".into()))
            .args([
                "build",
                "--manifest-path",
                manifest.to_str().expect("UTF-8 manifest path"),
                "--lib",
                "--no-default-features",
                "--offline",
                "--target-dir",
                root.to_str().expect("UTF-8 target path"),
            ])
            .output()
            .expect("run cargo build for compile fixtures");
        assert_success("build fixture library", &output);

        let deps = root.join("debug/deps");
        let mut libraries = fs::read_dir(&deps)
            .expect("read fixture dependencies")
            .filter_map(Result::ok)
            .map(|entry| entry.path())
            .filter(|path| {
                path.file_stem()
                    .and_then(OsStr::to_str)
                    .is_some_and(|name| name.starts_with("librekindle_client-"))
                    && path.extension() == Some(OsStr::new("rlib"))
            })
            .collect::<Vec<_>>();
        libraries.sort();
        assert_eq!(libraries.len(), 1, "one fixture library must be produced");

        let wasm_rustc_output = Command::new("rustup")
            .args(["which", "--toolchain", "nightly-2026-04-01", "rustc"])
            .output()
            .expect("locate qualified Wasm rustc");
        assert_success("locate qualified Wasm rustc", &wasm_rustc_output);
        let wasm_rustc = String::from_utf8(wasm_rustc_output.stdout)
            .expect("UTF-8 rustc path")
            .trim()
            .into();

        Self {
            root,
            deps,
            library: libraries.pop().expect("fixture library"),
            rustc: env::var_os("RUSTC").map_or_else(|| PathBuf::from("rustc"), PathBuf::from),
            wasm_rustc,
        }
    }

    fn compile_fixture(&self, fixture: &str) -> Output {
        let source = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("tests/ui")
            .join(fixture);
        let output = self
            .root
            .join(fixture.replace('/', "-"))
            .with_extension("bin");

        Command::new(&self.rustc)
            .arg("--edition=2024")
            .arg("--crate-type=bin")
            .arg("--emit=metadata")
            .arg("--out-dir")
            .arg(&output)
            .arg("--extern")
            .arg(format!("rekindle_client={}", self.library.display()))
            .arg("-L")
            .arg(format!("dependency={}", self.deps.display()))
            .arg(source)
            .output()
            .expect("compile public surface fixture")
    }

    fn compile_library(&self, cfgs: &[&str], target: Option<&str>) -> Output {
        let source = Path::new(env!("CARGO_MANIFEST_DIR")).join("src/lib.rs");
        let output = self.root.join(format!("library-{}", cfgs.join("-")));
        let mut command = Command::new(if target == Some("wasm32-unknown-unknown") {
            &self.wasm_rustc
        } else {
            &self.rustc
        });
        command
            .arg("--edition=2024")
            .arg("--crate-type=lib")
            .arg("--emit=metadata")
            .arg("--out-dir")
            .arg(output);

        if let Some(target) = target {
            command.arg("--target").arg(target);
        }
        for cfg in cfgs {
            command.arg("--cfg").arg(format!("feature=\"{cfg}\""));
        }

        command
            .arg(source)
            .output()
            .expect("compile feature matrix")
    }
}

impl Drop for Harness {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

#[test]
fn public_surface_compile_matrix() {
    let harness = Harness::new();

    assert_success(
        "exact public surface",
        &harness.compile_fixture("pass/public_surface.rs"),
    );

    for (fixture, expected) in [
        (
            "fail/missing_field.rs",
            &["missing field `application_id`"][..],
        ),
        ("fail/extra_field.rs", &["no field named `extra`"][..]),
        (
            "fail/application_id_lifetime.rs",
            &["does not live long enough"],
        ),
        ("fail/handoff_lifetime.rs", &["does not live long enough"]),
        (
            "fail/handoff_not_send_sync.rs",
            &[
                "cannot be sent between threads safely",
                "cannot be shared between threads safely",
            ],
        ),
        (
            "fail/future_not_send.rs",
            &["future cannot be sent between threads safely"],
        ),
        (
            "fail/callback_schema.rs",
            &["method `schema_version` has an incompatible type for trait"],
        ),
        (
            "fail/callback_snapshot.rs",
            &["method `snapshot` has an incompatible type for trait"],
        ),
        (
            "fail/callback_restore_lifetime.rs",
            &["method not compatible with trait", "lifetime mismatch"],
        ),
        (
            "fail/client_error_exhaustive.rs",
            &["non-exhaustive patterns", "wildcard `_` is necessary"],
        ),
        (
            "fail/handoff_error_exhaustive.rs",
            &["non-exhaustive patterns", "wildcard `_` is necessary"],
        ),
        (
            "fail/duplicate_public_name.rs",
            &["the name `ClientOptions` is defined multiple times"],
        ),
        (
            "fail/web_module_without_feature.rs",
            &["could not find `web` in `rekindle_client`"],
        ),
        (
            "fail/desktop_module_without_feature.rs",
            &["could not find `desktop` in `rekindle_client`"],
        ),
    ] {
        assert_failure(fixture, &harness.compile_fixture(fixture), expected);
    }

    assert_failure(
        "web feature on native",
        &harness.compile_library(&["web"], None),
        &["feature `web` is supported only for target_arch = wasm32"],
    );
    assert_failure(
        "web and desktop features",
        &harness.compile_library(&["web", "desktop"], None),
        &["features `web` and `desktop` are mutually exclusive"],
    );
    assert_failure(
        "desktop feature on Wasm",
        &harness.compile_library(&["desktop"], Some("wasm32-unknown-unknown")),
        &["feature `desktop` is supported only for non-Wasm targets"],
    );
}

fn assert_success(label: &str, output: &Output) {
    assert!(
        output.status.success(),
        "{label} failed:\n{}",
        String::from_utf8_lossy(&output.stderr)
    );
}

fn assert_failure(label: &str, output: &Output, expected: &[&str]) {
    assert!(!output.status.success(), "{label} unexpectedly compiled");
    let stderr = String::from_utf8_lossy(&output.stderr);
    for message in expected {
        assert!(
            stderr.contains(message),
            "{label} omitted {message:?}:\n{stderr}"
        );
    }
}
