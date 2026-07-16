use crate::{WASM_BINDGEN_SCHEMA, frame};
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::io::Read;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Component, Path, PathBuf};
use std::time::Instant;
use walkdir::WalkDir;

const MARKER: &str = ".rekindle-attempt";
const MANIFEST: &str = "rekindle-web-manifest-v1.json";
const BOOTSTRAP_TEMPLATE: &str = r#"export async function start(context) {
  if (!context || context.v !== 1) throw new Error("invalid Rekindle context");
  const styles = __REKINDLE_HOT_STYLES__;
  await Promise.all(styles.map((href) => new Promise((resolve, reject) => {
    const link = Object.assign(document.createElement("link"), { rel: "stylesheet", href });
    link.onload = resolve;
    link.onerror = reject;
    document.head.appendChild(link);
  })));
  const module = await import("./__REKINDLE_ENTRY__");
  await module.default();
}
"#;

pub fn run<R: Read>(mut input: R) -> Result<(), String> {
    let operation = frame::read(&mut input)?.ok_or_else(|| "missing web operation".to_string())?;
    if !operation.payload.is_empty() {
        return Err("web operation payload must be empty".into());
    }
    let op = operation.header["op"]
        .as_str()
        .unwrap_or_default()
        .to_owned();
    let request_id = operation.header["request_id"]
        .as_str()
        .unwrap_or_default()
        .to_owned();
    let result = match op.as_str() {
        "bindgen_web" => bindgen(&operation.header),
        "package_web" => package(&operation.header),
        "verify_web" => verify(&operation.header),
        _ => Err(OpError::new("invalid_request", "unknown web operation")),
    };
    if stdin_has_extra()? {
        return Err("extra frame after Web operation".into());
    }
    match result {
        Ok(value) => frame::write(&mut std::io::stdout().lock(), &value, &[]),
        Err(error) => frame::write(
            &mut std::io::stdout().lock(),
            &json!({
                "v": 1, "type": "operation_error", "request_id": request_id,
                "payload_len": 0, "op": op, "code": error.code,
                "message": error.message, "diagnostics": []
            }),
            &[],
        ),
    }
}

fn stdin_has_extra() -> Result<bool, String> {
    let mut descriptor = libc::pollfd {
        fd: 0,
        events: libc::POLLIN,
        revents: 0,
    };
    let result = unsafe { libc::poll(&mut descriptor, 1, 0) };
    if result < 0 {
        Err(std::io::Error::last_os_error().to_string())
    } else {
        Ok(result > 0 && descriptor.revents & libc::POLLIN != 0)
    }
}

struct OpError {
    code: &'static str,
    message: String,
}

impl OpError {
    fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into().chars().take(1_024).collect(),
        }
    }
}

type OpResult<T> = Result<T, OpError>;

fn bindgen(request: &Value) -> OpResult<Value> {
    const KEYS: &[&str] = &[
        "v",
        "type",
        "request_id",
        "payload_len",
        "op",
        "input_root",
        "input_wasm",
        "output_root",
        "output_stem",
        "debug",
        "source_maps",
        "expected_wasm_bindgen",
        "limits",
    ];
    require_operation(request, "bindgen_web", KEYS)?;
    if request["expected_wasm_bindgen"] != WASM_BINDGEN_SCHEMA {
        return Err(OpError::new(
            "incompatible_schema",
            "wasm-bindgen schema mismatch",
        ));
    }
    let input_root = validate_root(&request["input_root"], "read")?;
    if request["input_wasm"]["root_id"] != input_root.id {
        return Err(OpError::new("invalid_request", "file root substitution"));
    }
    let input = validate_input_file(&input_root, &request["input_wasm"])?;
    let output = validate_root(&request["output_root"], "write_empty")?;
    let limits = Limits::parse(&request["limits"])?;
    enforce_input_limits(&limits, &[input.size])?;
    let stem = request["output_stem"]
        .as_str()
        .ok_or_else(|| OpError::new("invalid_request", "invalid output stem"))?;
    if !relative(stem) || stem.contains('/') {
        return Err(OpError::new("invalid_request", "invalid output stem"));
    }
    let source_maps = request["source_maps"].as_str().unwrap_or_default();
    if !matches!(source_maps, "none" | "external") {
        return Err(OpError::new("invalid_request", "invalid source map policy"));
    }
    let started = Instant::now();
    let mut bindgen = wasm_bindgen_cli_support::Bindgen::new();
    bindgen.input_path(&input.path);
    bindgen.out_name(stem);
    bindgen
        .web(true)
        .map_err(|error| OpError::new("bindgen_failed", error.to_string()))?;
    bindgen.debug(request["debug"].as_bool().unwrap_or(false));
    bindgen.keep_debug(request["debug"].as_bool().unwrap_or(false));
    bindgen
        .generate(&output.path)
        .map_err(|error| OpError::new("bindgen_failed", error.to_string()))?;
    enforce_limits(&output.path, &limits, started)?;
    let files = describe_tree(&output, true)?;
    let js = files
        .iter()
        .find(|file| {
            file["path"]
                .as_str()
                .is_some_and(|path| path.ends_with(".js") && !path.ends_with(".d.ts"))
        })
        .and_then(|file| file["path"].as_str())
        .ok_or_else(|| OpError::new("bindgen_failed", "javascript entry was not generated"))?;
    let wasm = files
        .iter()
        .find(|file| {
            file["path"]
                .as_str()
                .is_some_and(|path| path.ends_with(".wasm"))
        })
        .and_then(|file| file["path"].as_str())
        .ok_or_else(|| OpError::new("bindgen_failed", "wasm output was not generated"))?;
    Ok(json!({
        "v": 1, "type": "operation_ok", "request_id": request["request_id"],
        "payload_len": 0, "op": "bindgen_web", "files": files,
        "javascript_entry": js, "wasm": wasm
    }))
}

fn package(request: &Value) -> OpResult<Value> {
    const KEYS: &[&str] = &[
        "v",
        "type",
        "request_id",
        "payload_len",
        "op",
        "bindgen_root",
        "bindgen_files",
        "public_root",
        "public_files",
        "bootstrap_template",
        "output_root",
        "manifest_base",
        "limits",
    ];
    require_operation(request, "package_web", KEYS)?;
    let bindgen_root = validate_root(&request["bindgen_root"], "read")?;
    let bindgen_files = validate_files(&bindgen_root, &request["bindgen_files"])?;
    let public = if request["public_root"].is_null() {
        if request["public_files"]
            .as_array()
            .is_some_and(Vec::is_empty)
        {
            None
        } else {
            return Err(OpError::new(
                "invalid_request",
                "public files require a root",
            ));
        }
    } else {
        let root = validate_root(&request["public_root"], "read")?;
        let files = validate_files(&root, &request["public_files"])?;
        Some((root, files))
    };
    let output = validate_root(&request["output_root"], "write_empty")?;
    let limits = Limits::parse(&request["limits"])?;
    let mut input_sizes = bindgen_files
        .iter()
        .map(|file| file.size)
        .collect::<Vec<_>>();
    if let Some((_root, files)) = &public {
        input_sizes.extend(files.iter().map(|file| file.size));
    }
    enforce_input_limits(&limits, &input_sizes)?;
    let template = request["bootstrap_template"]
        .as_object()
        .ok_or_else(|| OpError::new("invalid_request", "invalid template"))?;
    if template.len() != 2
        || template.get("id").and_then(Value::as_str) != Some("v1")
        || template.get("sha256").and_then(Value::as_str)
            != Some(&sha256(BOOTSTRAP_TEMPLATE.as_bytes()))
    {
        return Err(OpError::new(
            "incompatible_schema",
            "bootstrap template mismatch",
        ));
    }
    validate_manifest_base(&request["manifest_base"])?;
    let started = Instant::now();
    let members_root = output.path.join("members");
    fs::create_dir(&members_root).map_err(io_error)?;
    let mut sources = BTreeMap::new();
    for file in &bindgen_files {
        sources.insert(file.relative.clone(), file.path.clone());
    }
    if let Some((_root, files)) = public {
        for file in files {
            if file.relative.ends_with(".html") {
                return Err(OpError::new(
                    "unsupported_import",
                    "standalone HTML is not a Web member",
                ));
            }
            if sources.insert(file.relative.clone(), file.path).is_some() {
                return Err(OpError::new(
                    "asset_collision",
                    format!("asset collision: {}", file.relative),
                ));
            }
        }
    }
    let javascript = sources
        .keys()
        .find(|path| path.ends_with(".js") && !path.ends_with(".d.ts"))
        .cloned()
        .ok_or_else(|| OpError::new("unsupported_import", "bindgen javascript entry is missing"))?;
    for (relative_path, source) in &sources {
        let destination = members_root.join(relative_path);
        if let Some(parent) = destination.parent() {
            fs::create_dir_all(parent).map_err(io_error)?;
        }
        fs::copy(source, destination).map_err(io_error)?;
    }
    let bootstrap_path = "entry.js";
    let hot_styles = serde_jcs::to_string(&request["manifest_base"]["hot_styles"])
        .map_err(|error| OpError::new("internal", error.to_string()))?;
    let bootstrap = BOOTSTRAP_TEMPLATE
        .replace("__REKINDLE_ENTRY__", &javascript)
        .replace("__REKINDLE_HOT_STYLES__", &hot_styles);
    fs::write(members_root.join(bootstrap_path), bootstrap).map_err(io_error)?;

    let mut members = Vec::new();
    for entry in WalkDir::new(&members_root).min_depth(1).follow_links(false) {
        let entry = entry.map_err(|error| OpError::new("io_failed", error.to_string()))?;
        if !entry.file_type().is_file() {
            continue;
        }
        let relative_path = normalized_relative(entry.path(), &members_root)?;
        let bytes = fs::read(entry.path()).map_err(io_error)?;
        let role = if relative_path == bootstrap_path {
            "bootstrap"
        } else if relative_path.ends_with(".wasm") {
            "wasm"
        } else if relative_path.ends_with(".js") {
            "javascript"
        } else if relative_path.ends_with(".css") {
            "css"
        } else if relative_path.ends_with(".map") {
            "source_map"
        } else {
            "asset"
        };
        members.push(json!({
            "path": relative_path, "role": role, "sha256": sha256(&bytes),
            "size": bytes.len(), "mime": mime(entry.path()),
            "cache": if role == "bootstrap" { "no_cache" } else { "immutable" },
            "source_map": Value::Null
        }));
    }
    members.sort_by(|a, b| a["path"].as_str().cmp(&b["path"].as_str()));
    let member_paths = members
        .iter()
        .filter_map(|member| member["path"].as_str().map(str::to_owned))
        .collect::<BTreeSet<_>>();
    for member in &mut members {
        let Some(path) = member["path"].as_str() else {
            continue;
        };
        let map = format!("{path}.map");
        if member_paths.contains(&map) {
            member["source_map"] = json!(map);
        }
    }
    let mut edges =
        vec![json!({"from": bootstrap_path, "to": javascript, "kind": "dynamic_import"})];
    for member in &members {
        if member["role"] == "wasm" {
            edges.push(json!({"from": javascript, "to": member["path"], "kind": "wasm_url"}));
        }
        if let Some(source_map) = member["source_map"].as_str() {
            edges.push(json!({"from": member["path"], "to": source_map, "kind": "source_map"}));
        }
    }
    edges.sort_by(|a, b| {
        (a["from"].as_str(), a["to"].as_str(), a["kind"].as_str()).cmp(&(
            b["from"].as_str(),
            b["to"].as_str(),
            b["kind"].as_str(),
        ))
    });
    let identity_members = members
        .iter()
        .map(|member| {
            json!({
                "path": member["path"], "role": member["role"],
                "sha256": member["sha256"], "size": member["size"]
            })
        })
        .collect::<Vec<_>>();
    let identity = json!({
        "v": 1,
        "build_key": request["manifest_base"]["build"]["build_key"],
        "members": identity_members
    });
    let artifact_id = domain_digest("rekindle-web-artifact-v1\0", &identity)?;
    let base = request["manifest_base"].as_object().unwrap();
    let mut manifest = Map::new();
    for (key, value) in base {
        manifest.insert(key.clone(), value.clone());
    }
    manifest.insert("contract_version".into(), json!(1));
    manifest.insert("target".into(), json!("web"));
    manifest.insert("artifact_id".into(), json!(artifact_id));
    manifest.insert("entry".into(), json!(bootstrap_path));
    manifest.insert("members".into(), Value::Array(members));
    manifest.insert("edges".into(), Value::Array(edges));
    let without_digest = Value::Object(manifest.clone());
    let manifest_digest = domain_digest("rekindle-web-manifest-v1\0", &without_digest)?;
    manifest.insert("manifest_digest".into(), json!(manifest_digest));
    let manifest_value = Value::Object(manifest);
    let manifest_bytes = serde_jcs::to_vec(&manifest_value)
        .map_err(|error| OpError::new("internal", error.to_string()))?;
    fs::write(output.path.join(MANIFEST), manifest_bytes).map_err(io_error)?;
    validate_web_manifest(&manifest_value, &output)?;
    enforce_limits(&output.path, &limits, started)?;
    let files = describe_tree(&output, true)?;
    let manifest_descriptor = files
        .iter()
        .find(|file| file["path"] == MANIFEST)
        .cloned()
        .ok_or_else(|| OpError::new("internal", "manifest descriptor missing"))?;
    Ok(json!({
        "v": 1, "type": "operation_ok", "request_id": request["request_id"],
        "payload_len": 0, "op": "package_web", "files": files,
        "manifest": manifest_descriptor, "artifact_id": artifact_id,
        "manifest_digest": manifest_digest
    }))
}

fn verify(request: &Value) -> OpResult<Value> {
    const KEYS: &[&str] = &[
        "v",
        "type",
        "request_id",
        "payload_len",
        "op",
        "artifact_root",
        "manifest",
        "expected_manifest_digest",
        "limits",
    ];
    require_operation(request, "verify_web", KEYS)?;
    let root = root_for_file(request, &request["manifest"], "read")?;
    let manifest_path = validate_file(&root, &request["manifest"])?;
    let limits = Limits::parse(&request["limits"])?;
    let started = Instant::now();
    let bytes = fs::read(&manifest_path).map_err(io_error)?;
    let mut manifest: Value = serde_json::from_slice(&bytes)
        .map_err(|_| OpError::new("invalid_request", "invalid web manifest"))?;
    if serde_jcs::to_vec(&manifest).map_err(|error| OpError::new("internal", error.to_string()))?
        != bytes
    {
        return Err(OpError::new("input_changed", "manifest is not canonical"));
    }
    let expected_digest = request["expected_manifest_digest"]
        .as_str()
        .unwrap_or_default();
    let recorded_digest = manifest["manifest_digest"]
        .as_str()
        .unwrap_or_default()
        .to_owned();
    let (artifact_id, member_count, total_bytes) = validate_web_manifest(&manifest, &root)?;
    enforce_input_limits(&limits, &[bytes.len() as u64, total_bytes])?;
    if started.elapsed().as_millis() as u64 > limits.deadline_ms {
        return Err(OpError::new(
            "output_limit",
            "verification deadline exceeded",
        ));
    }
    manifest.as_object_mut().unwrap().remove("manifest_digest");
    let computed_digest = domain_digest("rekindle-web-manifest-v1\0", &manifest)?;
    if computed_digest != expected_digest || computed_digest != recorded_digest {
        return Err(OpError::new("input_changed", "manifest digest mismatch"));
    }
    Ok(json!({
        "v": 1, "type": "operation_ok", "request_id": request["request_id"],
        "payload_len": 0, "op": "verify_web", "artifact_id": artifact_id,
        "manifest_digest": computed_digest, "members_verified": member_count,
        "total_bytes": total_bytes
    }))
}

struct Root {
    id: String,
    path: PathBuf,
}

struct InputFile {
    relative: String,
    path: PathBuf,
    size: u64,
}

struct Limits {
    max_files: u64,
    max_input_bytes: u64,
    max_output_bytes: u64,
    deadline_ms: u64,
}

impl Limits {
    fn parse(value: &Value) -> OpResult<Self> {
        const KEYS: &[&str] = &[
            "max_files",
            "max_input_bytes",
            "max_output_bytes",
            "deadline_ms",
        ];
        if !frame::exact_keys(value, KEYS) {
            return Err(OpError::new("invalid_request", "invalid limits"));
        }
        let limits = Self {
            max_files: value["max_files"].as_u64().unwrap_or(0),
            max_input_bytes: value["max_input_bytes"].as_u64().unwrap_or(0),
            max_output_bytes: value["max_output_bytes"].as_u64().unwrap_or(0),
            deadline_ms: value["deadline_ms"].as_u64().unwrap_or(0),
        };
        if limits.max_files == 0
            || limits.max_input_bytes == 0
            || limits.max_output_bytes == 0
            || limits.deadline_ms == 0
        {
            Err(OpError::new("invalid_request", "limits must be positive"))
        } else {
            Ok(limits)
        }
    }
}

fn require_operation(value: &Value, op: &str, keys: &[&str]) -> OpResult<()> {
    if frame::exact_keys(value, keys)
        && value["v"] == 1
        && value["type"] == "operation"
        && value["payload_len"] == 0
        && value["op"] == op
    {
        Ok(())
    } else {
        Err(OpError::new("invalid_request", "invalid operation fields"))
    }
}

fn validate_root(value: &Value, mode: &str) -> OpResult<Root> {
    const KEYS: &[&str] = &["id", "path", "mode", "device"];
    if !frame::exact_keys(value, KEYS)
        || value["mode"] != mode
        || !frame::is_request_id(value.get("id"))
    {
        return Err(OpError::new("invalid_request", "invalid root descriptor"));
    }
    let path = PathBuf::from(value["path"].as_str().unwrap_or_default());
    if !path.is_absolute() {
        return Err(OpError::new("invalid_request", "root must be absolute"));
    }
    let metadata = fs::symlink_metadata(&path).map_err(io_error)?;
    if !metadata.file_type().is_dir()
        || metadata.uid() != unsafe { libc::geteuid() }
        || !no_symlink_components(&path)
        || device_identity(metadata.dev(), metadata.rdev())
            != value["device"].as_u64().unwrap_or(u64::MAX)
    {
        return Err(OpError::new("input_changed", "root identity changed"));
    }
    if mode == "write_empty" {
        let entries = fs::read_dir(&path)
            .map_err(io_error)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(io_error)?;
        if entries.iter().any(|entry| entry.file_name() != MARKER) {
            return Err(OpError::new("invalid_request", "output root is not empty"));
        }
        if let Some(marker) = entries.first() {
            let metadata = marker.metadata().map_err(io_error)?;
            if !metadata.file_type().is_file() || metadata.uid() != unsafe { libc::geteuid() } {
                return Err(OpError::new("invalid_request", "invalid attempt marker"));
            }
        }
    }
    Ok(Root {
        id: value["id"].as_str().unwrap().to_owned(),
        path,
    })
}

fn root_for_file(request: &Value, file: &Value, mode: &str) -> OpResult<Root> {
    let root_value = &request["artifact_root"];
    let root = validate_root(root_value, mode)?;
    if file["root_id"] != root.id {
        return Err(OpError::new("invalid_request", "file root substitution"));
    }
    Ok(root)
}

fn validate_files(root: &Root, value: &Value) -> OpResult<Vec<InputFile>> {
    let values = value
        .as_array()
        .ok_or_else(|| OpError::new("invalid_request", "files must be a list"))?;
    let mut paths = Vec::new();
    let mut previous = None;
    for descriptor in values {
        let relative_path = descriptor["path"].as_str().unwrap_or_default();
        if previous.is_some_and(|prior: &str| prior >= relative_path) {
            return Err(OpError::new(
                "invalid_request",
                "files must be sorted and unique",
            ));
        }
        paths.push(validate_input_file(root, descriptor)?);
        previous = Some(relative_path);
    }
    Ok(paths)
}

fn validate_file(root: &Root, value: &Value) -> OpResult<PathBuf> {
    const KEYS: &[&str] = &["root_id", "path", "sha256", "size", "mode"];
    if !frame::exact_keys(value, KEYS) || value["root_id"] != root.id {
        return Err(OpError::new("invalid_request", "invalid file descriptor"));
    }
    let relative_path = value["path"].as_str().unwrap_or_default();
    if !relative(relative_path) {
        return Err(OpError::new("asset_escape", "invalid relative path"));
    }
    let path = root.path.join(relative_path);
    if !no_symlink_below(&root.path, relative_path) {
        return Err(OpError::new("asset_escape", "symlink input is forbidden"));
    }
    let metadata = fs::symlink_metadata(&path)
        .map_err(|_| OpError::new("input_changed", "input file missing"))?;
    if !metadata.file_type().is_file()
        || (value["mode"] == "executable" && metadata.permissions().mode() & 0o100 == 0)
    {
        return Err(OpError::new("input_changed", "input type changed"));
    }
    let bytes = fs::read(&path).map_err(io_error)?;
    if value["sha256"] != sha256(&bytes) || value["size"].as_u64() != Some(bytes.len() as u64) {
        return Err(OpError::new("input_changed", "input digest changed"));
    }
    Ok(path)
}

fn validate_input_file(root: &Root, value: &Value) -> OpResult<InputFile> {
    let path = validate_file(root, value)?;
    Ok(InputFile {
        relative: value["path"].as_str().unwrap().to_owned(),
        path,
        size: value["size"].as_u64().unwrap(),
    })
}

fn describe_tree(root: &Root, allow_marker: bool) -> OpResult<Vec<Value>> {
    let mut files = Vec::new();
    for entry in WalkDir::new(&root.path).min_depth(1).follow_links(false) {
        let entry = entry.map_err(|error| OpError::new("io_failed", error.to_string()))?;
        if entry.file_type().is_symlink() {
            return Err(OpError::new("asset_escape", "symlink output is forbidden"));
        }
        if !entry.file_type().is_file() {
            continue;
        }
        let relative_path = normalized_relative(entry.path(), &root.path)?;
        if allow_marker && relative_path == MARKER {
            continue;
        }
        let bytes = fs::read(entry.path()).map_err(io_error)?;
        files.push(json!({
            "root_id": root.id, "path": relative_path, "sha256": sha256(&bytes),
            "size": bytes.len(), "mode": "data"
        }));
    }
    files.sort_by(|a, b| a["path"].as_str().cmp(&b["path"].as_str()));
    Ok(files)
}

fn validate_manifest_base(value: &Value) -> OpResult<()> {
    const KEYS: &[&str] = &[
        "rekindle_version",
        "application_id",
        "target",
        "build",
        "producer",
        "host_requirements",
        "hot_styles",
    ];
    let build = &value["build"];
    let producer = &value["producer"];
    let hot_styles = value["hot_styles"].as_array();
    if frame::exact_keys(value, KEYS)
        && value["target"] == "web"
        && value["rekindle_version"]
            .as_str()
            .is_some_and(|value| !value.is_empty())
        && value["application_id"]
            .as_str()
            .is_some_and(|value| !value.is_empty())
        && frame::exact_keys(
            build,
            &["build_key", "profile", "package", "binary", "features"],
        )
        && digest(build["build_key"].as_str())
        && build["profile"]
            .as_str()
            .is_some_and(|value| !value.is_empty())
        && build["package"]
            .as_str()
            .is_some_and(|value| !value.is_empty())
        && build["binary"]
            .as_str()
            .is_some_and(|value| !value.is_empty())
        && build["features"]
            .as_array()
            .is_some_and(|values| !values.is_empty())
        && strings_sorted_unique(&build["features"])
        && frame::exact_keys(
            producer,
            &[
                "kind",
                "rustc",
                "cargo",
                "rust_target",
                "wasm_bindgen",
                "gpui_revision",
                "helper_version",
                "helper_protocol",
                "compatibility_tuple_id",
            ],
        )
        && producer["kind"] == "canonical_web"
        && producer["helper_protocol"] == 1
        && [
            "rustc",
            "cargo",
            "rust_target",
            "wasm_bindgen",
            "gpui_revision",
            "helper_version",
            "compatibility_tuple_id",
        ]
        .iter()
        .all(|key| {
            producer[*key]
                .as_str()
                .is_some_and(|value| !value.is_empty())
        })
        && value["host_requirements"] == json!({"secure_context": true, "webgpu": true})
        && hot_styles.is_some()
        && string_values_sorted_unique(hot_styles.unwrap())
    {
        Ok(())
    } else {
        Err(OpError::new("invalid_request", "invalid manifest base"))
    }
}

fn validate_web_manifest(manifest: &Value, root: &Root) -> OpResult<(String, usize, u64)> {
    const ROOT_KEYS: &[&str] = &[
        "contract_version",
        "rekindle_version",
        "application_id",
        "target",
        "artifact_id",
        "build",
        "producer",
        "host_requirements",
        "entry",
        "hot_styles",
        "members",
        "edges",
        "manifest_digest",
    ];
    if !frame::exact_keys(manifest, ROOT_KEYS)
        || manifest["contract_version"] != 1
        || !digest(manifest["artifact_id"].as_str())
        || !digest(manifest["manifest_digest"].as_str())
    {
        return Err(OpError::new("invalid_request", "invalid manifest root"));
    }
    let base = json!({
        "rekindle_version": manifest["rekindle_version"],
        "application_id": manifest["application_id"],
        "target": manifest["target"],
        "build": manifest["build"],
        "producer": manifest["producer"],
        "host_requirements": manifest["host_requirements"],
        "hot_styles": manifest["hot_styles"]
    });
    validate_manifest_base(&base)?;
    let members = manifest["members"]
        .as_array()
        .ok_or_else(|| OpError::new("invalid_request", "invalid members"))?;
    let mut previous = None;
    let mut folded = BTreeSet::new();
    let mut member_paths = BTreeSet::new();
    let mut total_bytes = 0_u64;
    let mut identity_members = Vec::new();
    for member in members {
        const MEMBER_KEYS: &[&str] = &[
            "path",
            "role",
            "sha256",
            "size",
            "mime",
            "cache",
            "source_map",
        ];
        let path = member["path"].as_str().unwrap_or_default();
        if !frame::exact_keys(member, MEMBER_KEYS)
            || !relative(path)
            || previous.is_some_and(|prior: &str| prior >= path)
            || !folded.insert(path.to_lowercase())
            || !matches!(
                member["role"].as_str(),
                Some("bootstrap" | "javascript" | "wasm" | "css" | "asset" | "source_map")
            )
            || !digest(member["sha256"].as_str())
            || member["size"].as_u64().is_none()
            || member["mime"].as_str().is_none()
            || !matches!(member["cache"].as_str(), Some("no_cache" | "immutable"))
            || !(member["source_map"].is_null()
                || member["source_map"].as_str().is_some_and(relative))
        {
            return Err(OpError::new("invalid_request", "invalid manifest member"));
        }
        let member_path = root.path.join("members").join(path);
        if !no_symlink_below(&root.path.join("members"), path) {
            return Err(OpError::new("asset_escape", "member path escaped"));
        }
        let bytes = fs::read(member_path)
            .map_err(|_| OpError::new("input_changed", "member is missing"))?;
        if member["sha256"] != sha256(&bytes) || member["size"].as_u64() != Some(bytes.len() as u64)
        {
            return Err(OpError::new("input_changed", "member digest changed"));
        }
        total_bytes = total_bytes
            .checked_add(bytes.len() as u64)
            .ok_or_else(|| OpError::new("output_limit", "member bytes overflow"))?;
        identity_members.push(json!({
            "path": member["path"], "role": member["role"],
            "sha256": member["sha256"], "size": member["size"]
        }));
        member_paths.insert(path.to_owned());
        previous = Some(path);
    }
    let actual_members = WalkDir::new(root.path.join("members"))
        .min_depth(1)
        .follow_links(false)
        .into_iter()
        .map(|entry| entry.map_err(|error| OpError::new("io_failed", error.to_string())))
        .collect::<OpResult<Vec<_>>>()?
        .into_iter()
        .filter(|entry| entry.file_type().is_file())
        .map(|entry| normalized_relative(entry.path(), &root.path.join("members")))
        .collect::<OpResult<BTreeSet<_>>>()?;
    if actual_members != member_paths {
        return Err(OpError::new("input_changed", "member closure changed"));
    }
    let entry = manifest["entry"].as_str().unwrap_or_default();
    if !members.iter().any(|member| {
        member["path"] == entry && member["role"] == "bootstrap" && member["cache"] == "no_cache"
    }) {
        return Err(OpError::new("invalid_request", "invalid manifest entry"));
    }
    let edges = manifest["edges"]
        .as_array()
        .ok_or_else(|| OpError::new("invalid_request", "invalid edges"))?;
    let mut prior_edge: Option<(&str, &str, &str)> = None;
    for edge in edges {
        if !frame::exact_keys(edge, &["from", "to", "kind"]) {
            return Err(OpError::new("invalid_request", "invalid edge"));
        }
        let tuple = (
            edge["from"].as_str().unwrap_or_default(),
            edge["to"].as_str().unwrap_or_default(),
            edge["kind"].as_str().unwrap_or_default(),
        );
        if prior_edge.is_some_and(|prior| prior >= tuple)
            || !member_paths.contains(tuple.0)
            || !member_paths.contains(tuple.1)
            || !matches!(
                tuple.2,
                "esm_import"
                    | "dynamic_import"
                    | "wasm_url"
                    | "source_map"
                    | "css_url"
                    | "asset_url"
            )
        {
            return Err(OpError::new("unsupported_import", "invalid manifest edge"));
        }
        prior_edge = Some(tuple);
    }
    let bootstrap_edges = edges
        .iter()
        .filter(|edge| edge["from"] == entry && edge["kind"] == "dynamic_import")
        .collect::<Vec<_>>();
    if bootstrap_edges.len() != 1
        || !members.iter().any(|member| {
            member["path"] == bootstrap_edges[0]["to"] && member["role"] == "javascript"
        })
    {
        return Err(OpError::new(
            "unsupported_import",
            "bootstrap graph is incomplete",
        ));
    }
    for member in members {
        let required_kind = match member["role"].as_str() {
            Some("wasm") => Some("wasm_url"),
            Some("source_map") => Some("source_map"),
            _ => None,
        };
        if let Some(kind) = required_kind
            && !edges
                .iter()
                .any(|edge| edge["to"] == member["path"] && edge["kind"] == kind)
        {
            return Err(OpError::new(
                "unsupported_import",
                "member graph is incomplete",
            ));
        }
    }
    for hot_style in manifest["hot_styles"].as_array().unwrap() {
        let path = hot_style.as_str().unwrap();
        if !members
            .iter()
            .any(|member| member["path"] == path && member["role"] == "css")
        {
            return Err(OpError::new(
                "invalid_request",
                "hot style is not a CSS member",
            ));
        }
    }
    let identity = json!({
        "v": 1, "build_key": manifest["build"]["build_key"], "members": identity_members
    });
    let artifact_id = domain_digest("rekindle-web-artifact-v1\0", &identity)?;
    if manifest["artifact_id"] != artifact_id {
        return Err(OpError::new("input_changed", "artifact identity mismatch"));
    }
    Ok((artifact_id, members.len(), total_bytes))
}

fn enforce_limits(path: &Path, limits: &Limits, started: Instant) -> OpResult<()> {
    let mut count = 0_u64;
    let mut bytes = 0_u64;
    for entry in WalkDir::new(path).min_depth(1).follow_links(false) {
        let entry = entry.map_err(|error| OpError::new("io_failed", error.to_string()))?;
        if entry.file_type().is_file() {
            count += 1;
            bytes += entry
                .metadata()
                .map_err(|error| OpError::new("io_failed", error.to_string()))?
                .len();
        }
    }
    if count > limits.max_files
        || bytes > limits.max_output_bytes
        || started.elapsed().as_millis() as u64 > limits.deadline_ms
    {
        Err(OpError::new("output_limit", "operation limit exceeded"))
    } else {
        Ok(())
    }
}

fn enforce_input_limits(limits: &Limits, sizes: &[u64]) -> OpResult<()> {
    let count = sizes.len() as u64;
    let bytes = sizes
        .iter()
        .try_fold(0_u64, |total, size| total.checked_add(*size));
    if count > limits.max_files || bytes.is_none_or(|bytes| bytes > limits.max_input_bytes) {
        Err(OpError::new("output_limit", "input limit exceeded"))
    } else {
        Ok(())
    }
}

fn normalized_relative(path: &Path, root: &Path) -> OpResult<String> {
    let relative_path = path
        .strip_prefix(root)
        .map_err(|_| OpError::new("asset_escape", "path escaped root"))?;
    let value = relative_path
        .to_str()
        .ok_or_else(|| OpError::new("asset_escape", "path is not UTF-8"))?
        .replace('\\', "/");
    if relative(&value) {
        Ok(value)
    } else {
        Err(OpError::new("asset_escape", "invalid path"))
    }
}

fn relative(value: &str) -> bool {
    !value.is_empty()
        && !Path::new(value).is_absolute()
        && !value.contains('\\')
        && !value.as_bytes().contains(&0)
        && Path::new(value)
            .components()
            .all(|component| matches!(component, Component::Normal(_)))
}

fn digest(value: Option<&str>) -> bool {
    value.is_some_and(|value| {
        value.len() == 64
            && value
                .bytes()
                .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
    })
}

fn strings_sorted_unique(value: &Value) -> bool {
    value
        .as_array()
        .is_some_and(|values| string_values_sorted_unique(values))
}

fn string_values_sorted_unique(values: &[Value]) -> bool {
    values.windows(2).all(|pair| {
        pair[0]
            .as_str()
            .zip(pair[1].as_str())
            .is_some_and(|(left, right)| left < right)
    }) && values
        .iter()
        .all(|value| value.as_str().is_some_and(relative))
}

fn no_symlink_components(path: &Path) -> bool {
    let mut current = PathBuf::new();
    for component in path.components() {
        current.push(component.as_os_str());
        if matches!(component, Component::RootDir) {
            continue;
        }
        match fs::symlink_metadata(&current) {
            Ok(metadata) if !metadata.file_type().is_symlink() => {}
            _ => return false,
        }
    }
    true
}

fn no_symlink_below(root: &Path, relative_path: &str) -> bool {
    let mut current = root.to_path_buf();
    for component in Path::new(relative_path).components() {
        current.push(component.as_os_str());
        match fs::symlink_metadata(&current) {
            Ok(metadata) if !metadata.file_type().is_symlink() => {}
            _ => return false,
        }
    }
    true
}

fn domain_digest(domain: &str, value: &Value) -> OpResult<String> {
    let canonical =
        serde_jcs::to_vec(value).map_err(|error| OpError::new("internal", error.to_string()))?;
    let mut digest = Sha256::new();
    digest.update(domain.as_bytes());
    digest.update(canonical);
    Ok(hex::encode(digest.finalize()))
}

fn sha256(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

fn mime(path: &Path) -> &'static str {
    match path.extension().and_then(|extension| extension.to_str()) {
        Some("js") => "text/javascript",
        Some("wasm") => "application/wasm",
        Some("css") => "text/css",
        Some("json") | Some("map") => "application/json",
        Some("svg") => "image/svg+xml",
        Some("png") => "image/png",
        _ => "application/octet-stream",
    }
}

fn io_error(error: std::io::Error) -> OpError {
    OpError::new("io_failed", error.to_string())
}

fn device_identity(device: u64, special_device: u64) -> u64 {
    device * 4_294_967_296 + special_device
}
