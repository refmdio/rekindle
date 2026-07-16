mod exec;
mod frame;
mod guardian;
mod web;

use serde::Serialize;
use serde_json::{Value, json};
use std::io::{self, Write};

const WASM_BINDGEN_SCHEMA: &str = "0.2.121";

#[derive(Serialize)]
struct Compatibility<'a> {
    helper_version: &'a str,
    toolframe: u32,
    exec_protocol: u32,
    web_protocol: u32,
    wasm_bindgen_schema: &'a str,
    web_manifest: u32,
    native_manifest: u32,
}

fn compatibility() -> Compatibility<'static> {
    Compatibility {
        helper_version: env!("CARGO_PKG_VERSION"),
        toolframe: 1,
        exec_protocol: 1,
        web_protocol: 1,
        wasm_bindgen_schema: WASM_BINDGEN_SCHEMA,
        web_manifest: 1,
        native_manifest: 1,
    }
}

fn compatibility_value() -> Value {
    serde_json::to_value(compatibility()).expect("static compatibility serializes")
}

fn host() -> Value {
    json!({"os": std::env::consts::OS, "arch": std::env::consts::ARCH})
}

fn main() {
    let result = run();
    if let Err(error) = result {
        let bounded = error.chars().take(512).collect::<String>();
        let _ = writeln!(io::stderr(), "rekindle_toolchain: {bounded}");
        std::process::exit(2);
    }
}

fn run() -> Result<(), String> {
    let arguments = std::env::args().collect::<Vec<_>>();
    let mode = match arguments.as_slice() {
        [_, mode] if mode == "exec-v1" || mode == "web-v1" => mode.clone(),
        _ => return Err("expected exactly one subcommand: exec-v1 or web-v1".into()),
    };

    if mode == "exec-v1" && !matches!(std::env::consts::OS, "linux" | "macos") {
        return Err("exec-v1 requires a supported POSIX host".into());
    }

    let stdin = io::stdin();
    let mut input = stdin.lock();
    let hello = frame::read(&mut input)?.ok_or_else(|| "missing hello".to_string())?;
    let request_id = admit_hello(&hello.header, &mode)?;
    let hello_object = hello.header.as_object().expect("admitted hello object");
    let response = json!({
        "v": 1,
        "type": "hello_ok",
        "request_id": request_id,
        "payload_len": 0,
        "session_nonce": hello_object["session_nonce"],
        "mode": mode,
        "actual": compatibility_value(),
        "host": host()
    });
    frame::write(&mut io::stdout().lock(), &response, &[])?;

    if mode == "exec-v1" {
        exec::run(input)
    } else {
        web::run(input)
    }
}

fn admit_hello(header: &Value, mode: &str) -> Result<String, String> {
    let hello = echoable_hello(header).ok_or_else(|| "invalid hello".to_string())?;

    if hello.mode != mode {
        return hello_error(&hello, mode, "protocol_mismatch");
    }
    if hello.host != &host() {
        return hello_error(&hello, mode, "host_mismatch");
    }
    if hello.expected != &compatibility_value() {
        let actual = compatibility_value();
        let code = if hello.expected.get("toolframe") != actual.get("toolframe")
            || hello.expected.get("exec_protocol") != actual.get("exec_protocol")
            || hello.expected.get("web_protocol") != actual.get("web_protocol")
        {
            "protocol_mismatch"
        } else if hello.expected.get("wasm_bindgen_schema") != actual.get("wasm_bindgen_schema")
            || hello.expected.get("web_manifest") != actual.get("web_manifest")
            || hello.expected.get("native_manifest") != actual.get("native_manifest")
        {
            "schema_mismatch"
        } else {
            "version_mismatch"
        };
        return hello_error(&hello, mode, code);
    }
    Ok(hello.request_id.to_owned())
}

struct EchoableHello<'a> {
    request_id: &'a str,
    session_nonce: &'a str,
    mode: &'a str,
    expected: &'a Value,
    host: &'a Value,
}

fn echoable_hello(header: &Value) -> Option<EchoableHello<'_>> {
    const KEYS: &[&str] = &[
        "v",
        "type",
        "request_id",
        "payload_len",
        "session_nonce",
        "mode",
        "expected",
        "host",
    ];
    if !frame::exact_keys(header, KEYS) {
        return None;
    }
    let object = header.as_object().expect("exact keys requires object");
    let request_id = object["request_id"].as_str()?;
    let session_nonce = object["session_nonce"].as_str()?;
    let hello_mode = object["mode"].as_str()?;

    if object["v"] != 1
        || object["type"] != "hello"
        || object["payload_len"] != 0
        || !frame::is_request_id(object.get("request_id"))
        || session_nonce.len() != 64
        || !session_nonce
            .bytes()
            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
        || !matches!(hello_mode, "exec-v1" | "web-v1")
        || !valid_compatibility(&object["expected"])
        || !valid_host(&object["host"])
    {
        return None;
    }

    Some(EchoableHello {
        request_id,
        session_nonce,
        mode: hello_mode,
        expected: &object["expected"],
        host: &object["host"],
    })
}

fn valid_compatibility(value: &Value) -> bool {
    const KEYS: &[&str] = &[
        "helper_version",
        "toolframe",
        "exec_protocol",
        "web_protocol",
        "wasm_bindgen_schema",
        "web_manifest",
        "native_manifest",
    ];

    frame::exact_keys(value, KEYS)
        && value["helper_version"].is_string()
        && value["toolframe"].as_u64().is_some()
        && value["exec_protocol"].as_u64().is_some()
        && value["web_protocol"].as_u64().is_some()
        && value["wasm_bindgen_schema"].is_string()
        && value["web_manifest"].as_u64().is_some()
        && value["native_manifest"].as_u64().is_some()
}

fn valid_host(value: &Value) -> bool {
    const KEYS: &[&str] = &["os", "arch"];

    frame::exact_keys(value, KEYS) && value["os"].is_string() && value["arch"].is_string()
}

fn hello_error<T>(hello: &EchoableHello<'_>, mode: &str, code: &str) -> Result<T, String> {
    let response = json!({
        "v": 1,
        "type": "hello_error",
        "request_id": hello.request_id,
        "payload_len": 0,
        "session_nonce": hello.session_nonce,
        "mode": mode,
        "code": code,
        "expected": hello.expected,
        "actual": compatibility_value(),
        "host": host()
    });
    frame::write(&mut io::stdout().lock(), &response, &[])?;
    Err(format!("hello rejected: {code}"))
}
