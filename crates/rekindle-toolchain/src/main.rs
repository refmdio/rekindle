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
    if !hello.payload.is_empty() {
        return Err("hello payload must be empty".into());
    }
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
        return Err("invalid hello fields".into());
    }
    let object = header.as_object().expect("exact keys requires object");
    let nonce = object["session_nonce"].as_str().unwrap_or_default();
    if object["type"] != "hello"
        || object["payload_len"] != 0
        || object["mode"] != mode
        || nonce.len() != 64
        || !nonce
            .bytes()
            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
    {
        return Err("invalid hello".into());
    }
    if object["host"] != host() {
        return hello_error(header, mode, "host_mismatch");
    }
    if object["expected"] != compatibility_value() {
        let expected = &object["expected"];
        let actual = compatibility_value();
        let code = if expected.get("toolframe") != actual.get("toolframe")
            || expected.get("exec_protocol") != actual.get("exec_protocol")
            || expected.get("web_protocol") != actual.get("web_protocol")
        {
            "protocol_mismatch"
        } else if expected.get("wasm_bindgen_schema") != actual.get("wasm_bindgen_schema")
            || expected.get("web_manifest") != actual.get("web_manifest")
            || expected.get("native_manifest") != actual.get("native_manifest")
        {
            "schema_mismatch"
        } else {
            "version_mismatch"
        };
        return hello_error(header, mode, code);
    }
    Ok(object["request_id"].as_str().unwrap().to_owned())
}

fn hello_error<T>(header: &Value, mode: &str, code: &str) -> Result<T, String> {
    let object = header.as_object().ok_or("invalid hello")?;
    let response = json!({
        "v": 1,
        "type": "hello_error",
        "request_id": object["request_id"],
        "payload_len": 0,
        "session_nonce": object["session_nonce"],
        "mode": mode,
        "code": code,
        "expected": object["expected"],
        "actual": compatibility_value(),
        "host": host()
    });
    frame::write(&mut io::stdout().lock(), &response, &[])?;
    Err(format!("hello rejected: {code}"))
}
