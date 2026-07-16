use crate::{WASM_BINDGEN_SCHEMA, frame};
use semver::Version;
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::io::Read;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Component, Path, PathBuf};
use std::time::Instant;
use tree_sitter::{Node, Parser};
use unicode_casefold::UnicodeCaseFold;
use unicode_normalization::UnicodeNormalization;
use walkdir::WalkDir;

const MARKER: &str = ".rekindle-attempt";
const MANIFEST: &str = "rekindle-web-manifest-v1.json";
const MAX_PATH_BYTES: usize = 4_096;
const MAX_MANIFEST_STRING_BYTES: usize = 4_096;
const BOOTSTRAP_TEMPLATE: &str = r#"export async function start(context) {
  if (!context || context.v !== 1) throw new Error("invalid Rekindle context");
  const styles = __REKINDLE_HOT_STYLES__;
  await Promise.all(styles.map((href) => new Promise((resolve, reject) => {
    const link = Object.assign(document.createElement("link"), { rel: "stylesheet", href });
    link.onload = resolve;
    link.onerror = reject;
    document.head.appendChild(link);
  })));
  const module = await import(__REKINDLE_ENTRY__);
  const wasm = new URL(__REKINDLE_WASM__, import.meta.url);
  await module.default(wasm);
}
"#;

#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd)]
struct GraphEdge {
    from: String,
    to: String,
    kind: &'static str,
}

struct DerivedGraph {
    edges: BTreeSet<GraphEdge>,
    source_maps: BTreeMap<String, String>,
}

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

#[derive(Debug)]
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
    validate_wasm_header(&input.path)?;
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
    let debug = request["debug"]
        .as_bool()
        .ok_or_else(|| OpError::new("invalid_request", "debug must be boolean"))?;
    let started = Instant::now();
    let mut bindgen = wasm_bindgen_cli_support::Bindgen::new();
    bindgen.input_path(&input.path);
    bindgen.out_name(stem);
    bindgen
        .web(true)
        .map_err(|error| OpError::new("bindgen_failed", error.to_string()))?;
    bindgen.debug(debug);
    bindgen.keep_debug(debug);
    bindgen
        .generate(&output.path)
        .map_err(|error| OpError::new("bindgen_failed", error.to_string()))?;
    apply_source_map(&output, stem, source_maps)?;
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

fn validate_wasm_header(path: &Path) -> OpResult<()> {
    let bytes = fs::read(path).map_err(io_error)?;
    if bytes.len() < 8 || bytes[..8] != [0, 97, 115, 109, 1, 0, 0, 0] {
        Err(OpError::new("invalid_wasm", "invalid WebAssembly header"))
    } else {
        Ok(())
    }
}

fn apply_source_map(output: &Root, stem: &str, policy: &str) -> OpResult<()> {
    let javascript_name = format!("{stem}.js");
    let javascript_path = output.path.join(&javascript_name);
    let javascript = fs::read_to_string(&javascript_path)
        .map_err(|error| OpError::new("bindgen_failed", error.to_string()))?;

    if policy == "none" {
        if javascript.contains("sourceMappingURL=")
            || output.path.join(format!("{javascript_name}.map")).exists()
        {
            return Err(OpError::new(
                "bindgen_failed",
                "source map output violates disabled policy",
            ));
        }
        return Ok(());
    }

    let mappings = identity_mappings(&javascript);
    let source_map = json!({
        "version": 3,
        "file": javascript_name,
        "sources": [format!("wasm-bindgen://generated/{javascript_name}")],
        "sourcesContent": [javascript],
        "names": [],
        "mappings": mappings
    });
    let source_map_bytes = serde_jcs::to_vec(&source_map)
        .map_err(|error| OpError::new("internal", error.to_string()))?;
    let source_map_name = format!("{javascript_name}.map");
    fs::write(output.path.join(&source_map_name), source_map_bytes).map_err(io_error)?;

    let mut mapped_javascript = source_map["sourcesContent"][0].as_str().unwrap().to_owned();
    if !mapped_javascript.ends_with('\n') {
        mapped_javascript.push('\n');
    }
    mapped_javascript.push_str(&format!("//# sourceMappingURL={source_map_name}\n"));
    fs::write(javascript_path, mapped_javascript).map_err(io_error)
}

fn identity_mappings(source: &str) -> String {
    let line_count = source.lines().count().max(1);
    std::iter::once("AAAA")
        .chain(std::iter::repeat_n("AACA", line_count.saturating_sub(1)))
        .collect::<Vec<_>>()
        .join(";")
}

fn derive_graph(
    members_root: &Path,
    member_roles: &BTreeMap<String, String>,
    entry: &str,
    hot_styles: &[Value],
) -> OpResult<DerivedGraph> {
    let mut graph = DerivedGraph {
        edges: BTreeSet::new(),
        source_maps: BTreeMap::new(),
    };
    for style in hot_styles {
        let style = style
            .as_str()
            .ok_or_else(|| OpError::new("invalid_request", "invalid hot style"))?;
        add_edge(&mut graph, member_roles, entry, style, "css_url")?;
    }

    for (path, role) in member_roles {
        let bytes = fs::read(members_root.join(path)).map_err(io_error)?;
        let references = match role.as_str() {
            "javascript" | "bootstrap" => javascript_references(&bytes)?,
            "css" => css_references(&bytes)?,
            _ => Vec::new(),
        };
        for (specifier, kind, module_import) in references {
            let target = resolve_reference(path, &specifier, module_import)?;
            add_edge(&mut graph, member_roles, path, &target, kind)?;
            if kind == "source_map"
                && graph
                    .source_maps
                    .insert(path.clone(), target.clone())
                    .is_some_and(|existing| existing != target)
            {
                return Err(OpError::new(
                    "unsupported_import",
                    "multiple source maps for one member",
                ));
            }
        }
    }
    Ok(graph)
}

fn add_edge(
    graph: &mut DerivedGraph,
    member_roles: &BTreeMap<String, String>,
    from: &str,
    to: &str,
    kind: &'static str,
) -> OpResult<()> {
    if !member_roles.contains_key(from) {
        return Err(OpError::new("unsupported_import", "edge source is missing"));
    }
    let target = to.to_owned();
    if !target.starts_with("https://") && !member_roles.contains_key(&target) {
        return Err(OpError::new(
            "unsupported_import",
            format!("unresolved Web reference: {target}"),
        ));
    }
    graph.edges.insert(GraphEdge {
        from: from.to_owned(),
        to: target,
        kind,
    });
    Ok(())
}

fn resolve_reference(from: &str, specifier: &str, module_import: bool) -> OpResult<String> {
    if valid_https_url(specifier) {
        return Ok(specifier.to_owned());
    }
    if specifier.starts_with("https:")
        || specifier.starts_with("//")
        || specifier.starts_with('/')
        || specifier.contains(':')
        || specifier.contains(['\\', '\0', '?', '#', '%'])
        || specifier.chars().any(char::is_whitespace)
    {
        return Err(OpError::new(
            "unsupported_import",
            format!("forbidden Web reference: {specifier}"),
        ));
    }
    if module_import && !specifier.starts_with("./") {
        return Err(OpError::new(
            "unsupported_import",
            format!("bare module import is unsupported: {specifier}"),
        ));
    }
    let relative = specifier.strip_prefix("./").unwrap_or(specifier);
    let segments = relative.split('/').collect::<Vec<_>>();
    if relative.is_empty()
        || segments
            .iter()
            .any(|segment| segment.is_empty() || matches!(*segment, "." | ".."))
    {
        return Err(OpError::new(
            "unsupported_import",
            format!("invalid relative Web reference: {specifier}"),
        ));
    }
    let parent = Path::new(from)
        .parent()
        .and_then(Path::to_str)
        .unwrap_or_default();
    Ok(if parent.is_empty() {
        relative.to_owned()
    } else {
        format!("{parent}/{relative}")
    })
}

fn valid_https_url(value: &str) -> bool {
    let Some(rest) = value.strip_prefix("https://") else {
        return false;
    };
    let authority = rest.split('/').next().unwrap_or_default();
    !authority.is_empty()
        && !value.contains(['\\', '\0', '"', '\'', '<', '>'])
        && !value.chars().any(char::is_whitespace)
}

fn javascript_references(bytes: &[u8]) -> OpResult<Vec<(String, &'static str, bool)>> {
    let source = std::str::from_utf8(bytes)
        .map_err(|_| OpError::new("unsupported_import", "JavaScript is not UTF-8"))?;
    let mut parser = Parser::new();
    parser
        .set_language(&tree_sitter_javascript::LANGUAGE.into())
        .map_err(|error| OpError::new("internal", error.to_string()))?;
    let tree = parser
        .parse(source, None)
        .ok_or_else(|| OpError::new("internal", "JavaScript parser returned no tree"))?;
    if tree.root_node().has_error() {
        return Err(OpError::new(
            "unsupported_import",
            "JavaScript contains syntax errors",
        ));
    }
    let mut references = Vec::new();
    collect_javascript_references(tree.root_node(), source.as_bytes(), &mut references)?;
    Ok(references)
}

fn collect_javascript_references(
    node: Node<'_>,
    source: &[u8],
    references: &mut Vec<(String, &'static str, bool)>,
) -> OpResult<()> {
    match node.kind() {
        "import_statement" | "export_statement" => {
            if let Some(specifier) = node.child_by_field_name("source") {
                references.push((string_literal(specifier, source)?, "esm_import", true));
            }
        }
        "call_expression" => {
            let function = node.child_by_field_name("function");
            if function.is_some_and(|function| function.kind() == "import") {
                let arguments = node
                    .child_by_field_name("arguments")
                    .ok_or_else(|| OpError::new("unsupported_import", "invalid dynamic import"))?;
                if arguments.named_child_count() != 1 {
                    return Err(OpError::new(
                        "unsupported_import",
                        "dynamic import must have one literal argument",
                    ));
                }
                let specifier = arguments.named_child(0).unwrap();
                references.push((string_literal(specifier, source)?, "dynamic_import", true));
            }
        }
        "new_expression" => {
            let constructor = node.child_by_field_name("constructor");
            let arguments = node.child_by_field_name("arguments");
            if constructor.is_some_and(|constructor| node_text(constructor, source) == "URL")
                && arguments.is_some_and(|arguments| arguments.named_child_count() == 2)
            {
                let arguments = arguments.unwrap();
                let base = arguments.named_child(1).unwrap();
                if node_text(base, source) == "import.meta.url" {
                    let specifier = string_literal(arguments.named_child(0).unwrap(), source)?;
                    let kind = if reference_path(&specifier).ends_with(".wasm") {
                        "wasm_url"
                    } else {
                        "asset_url"
                    };
                    references.push((specifier, kind, false));
                }
            }
        }
        "comment" => {
            if let Some(specifier) = source_map_comment(node_text(node, source)) {
                references.push((specifier, "source_map", false));
            }
        }
        _ => {}
    }
    let mut cursor = node.walk();
    for child in node.children(&mut cursor) {
        collect_javascript_references(child, source, references)?;
    }
    Ok(())
}

fn string_literal(node: Node<'_>, source: &[u8]) -> OpResult<String> {
    if node.kind() != "string" {
        return Err(OpError::new(
            "unsupported_import",
            "Web references must use string literals",
        ));
    }
    let raw = node_text(node, source);
    if raw.len() < 2 || raw.contains('\\') {
        return Err(OpError::new(
            "unsupported_import",
            "escaped Web references are unsupported",
        ));
    }
    Ok(raw[1..raw.len() - 1].to_owned())
}

fn node_text<'a>(node: Node<'_>, source: &'a [u8]) -> &'a str {
    std::str::from_utf8(&source[node.byte_range()]).unwrap_or_default()
}

fn source_map_comment(comment: &str) -> Option<String> {
    let content = comment
        .strip_prefix("//")
        .or_else(|| {
            comment
                .strip_prefix("/*")
                .and_then(|value| value.strip_suffix("*/"))
        })?
        .trim();
    let value = content
        .strip_prefix("# sourceMappingURL=")
        .or_else(|| content.strip_prefix("@ sourceMappingURL="))?;
    let value = value.trim();
    (!value.is_empty()).then(|| value.to_owned())
}

fn reference_path(value: &str) -> &str {
    value.split(['?', '#']).next().unwrap_or(value)
}

fn css_references(bytes: &[u8]) -> OpResult<Vec<(String, &'static str, bool)>> {
    let source = std::str::from_utf8(bytes)
        .map_err(|_| OpError::new("unsupported_import", "CSS is not UTF-8"))?;
    let bytes = source.as_bytes();
    let mut references = Vec::new();
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index..].starts_with(b"/*") {
            let end = find_bytes(bytes, index + 2, b"*/")
                .ok_or_else(|| OpError::new("unsupported_import", "unterminated CSS comment"))?;
            if let Some(specifier) = source_map_comment(&source[index..end + 2]) {
                references.push((specifier, "source_map", false));
            }
            index = end + 2;
            continue;
        }
        if matches!(bytes[index], b'\'' | b'"') {
            index = skip_quoted(bytes, index)?;
            continue;
        }
        if css_keyword(bytes, index, b"@import") {
            let mut cursor = skip_ascii_space(bytes, index + 7);
            let (specifier, end) = if cursor < bytes.len() && matches!(bytes[cursor], b'\'' | b'"')
            {
                read_quoted(bytes, cursor)?
            } else if css_keyword(bytes, cursor, b"url") {
                cursor = skip_ascii_space(bytes, cursor + 3);
                read_css_url(bytes, cursor)?
            } else {
                return Err(OpError::new(
                    "unsupported_import",
                    "CSS imports must use a literal URL",
                ));
            };
            references.push((specifier, "css_url", false));
            index = end;
            continue;
        }
        if css_keyword(bytes, index, b"url") {
            let cursor = skip_ascii_space(bytes, index + 3);
            let (specifier, end) = read_css_url(bytes, cursor)?;
            references.push((specifier, "asset_url", false));
            index = end;
            continue;
        }
        index += 1;
    }
    Ok(references)
}

fn css_keyword(bytes: &[u8], index: usize, keyword: &[u8]) -> bool {
    let end = index.saturating_add(keyword.len());
    end <= bytes.len()
        && bytes[index..end].eq_ignore_ascii_case(keyword)
        && (index == 0 || !css_name_byte(bytes[index - 1]))
        && (end == bytes.len() || !css_name_byte(bytes[end]))
}

fn css_name_byte(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-')
}

fn read_css_url(bytes: &[u8], open: usize) -> OpResult<(String, usize)> {
    if bytes.get(open) != Some(&b'(') {
        return Err(OpError::new("unsupported_import", "invalid CSS url()"));
    }
    let start = skip_ascii_space(bytes, open + 1);
    let (value, end) = if bytes
        .get(start)
        .is_some_and(|byte| matches!(byte, b'\'' | b'"'))
    {
        read_quoted(bytes, start)?
    } else {
        let close = bytes[start..]
            .iter()
            .position(|byte| *byte == b')')
            .map(|offset| start + offset)
            .ok_or_else(|| OpError::new("unsupported_import", "unterminated CSS url()"))?;
        let raw = std::str::from_utf8(&bytes[start..close])
            .map_err(|_| OpError::new("unsupported_import", "invalid CSS URL"))?
            .trim();
        if raw.is_empty() || raw.contains(['\\', '\'', '"', '(']) {
            return Err(OpError::new("unsupported_import", "invalid CSS URL"));
        }
        (raw.to_owned(), close)
    };
    let close = skip_ascii_space(bytes, end);
    if bytes.get(close) != Some(&b')') {
        return Err(OpError::new("unsupported_import", "invalid CSS url()"));
    }
    Ok((value, close + 1))
}

fn read_quoted(bytes: &[u8], start: usize) -> OpResult<(String, usize)> {
    let quote = bytes[start];
    let mut index = start + 1;
    while index < bytes.len() {
        if bytes[index] == b'\\' {
            return Err(OpError::new(
                "unsupported_import",
                "escaped Web references are unsupported",
            ));
        }
        if bytes[index] == quote {
            let value = std::str::from_utf8(&bytes[start + 1..index])
                .map_err(|_| OpError::new("unsupported_import", "invalid Web reference"))?;
            return Ok((value.to_owned(), index + 1));
        }
        index += 1;
    }
    Err(OpError::new(
        "unsupported_import",
        "unterminated string literal",
    ))
}

fn skip_quoted(bytes: &[u8], start: usize) -> OpResult<usize> {
    let quote = bytes[start];
    let mut index = start + 1;
    while index < bytes.len() {
        if bytes[index] == b'\\' {
            index = index.saturating_add(2);
        } else if bytes[index] == quote {
            return Ok(index + 1);
        } else {
            index += 1;
        }
    }
    Err(OpError::new(
        "unsupported_import",
        "unterminated string literal",
    ))
}

fn skip_ascii_space(bytes: &[u8], mut index: usize) -> usize {
    while bytes.get(index).is_some_and(u8::is_ascii_whitespace) {
        index += 1;
    }
    index
}

fn find_bytes(haystack: &[u8], start: usize, needle: &[u8]) -> Option<usize> {
    haystack[start..]
        .windows(needle.len())
        .position(|window| window == needle)
        .map(|offset| start + offset)
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
    validate_manifest_base(&request["manifest_base"], false)?;
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
    let javascript = bindgen_files
        .iter()
        .filter(|file| file.relative.ends_with(".js") && !file.relative.ends_with(".d.ts"))
        .map(|file| file.relative.clone())
        .collect::<Vec<_>>();
    if javascript.len() != 1 {
        return Err(OpError::new(
            "unsupported_import",
            "bindgen output must contain exactly one JavaScript entry",
        ));
    }
    let javascript = &javascript[0];
    let wasm = bindgen_files
        .iter()
        .filter(|file| file.relative.ends_with(".wasm"))
        .map(|file| file.relative.clone())
        .collect::<Vec<_>>();
    if wasm.len() != 1 {
        return Err(OpError::new(
            "unsupported_import",
            "bindgen output must contain exactly one Wasm member",
        ));
    }
    let wasm = &wasm[0];
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
    let javascript_specifier = serde_jcs::to_string(&format!("./{javascript}"))
        .map_err(|error| OpError::new("internal", error.to_string()))?;
    let wasm_specifier = serde_jcs::to_string(&format!("./{wasm}"))
        .map_err(|error| OpError::new("internal", error.to_string()))?;
    let bootstrap = BOOTSTRAP_TEMPLATE
        .replace("__REKINDLE_ENTRY__", &javascript_specifier)
        .replace("__REKINDLE_WASM__", &wasm_specifier)
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
        let (mime, cache) = member_metadata(role, &relative_path).ok_or_else(|| {
            OpError::new(
                "unsupported_import",
                format!("invalid role/extension pair: {relative_path}"),
            )
        })?;
        members.push(json!({
            "path": relative_path, "role": role, "sha256": sha256(&bytes),
            "size": bytes.len(), "mime": mime, "cache": cache,
            "source_map": Value::Null
        }));
    }
    members.sort_by(|a, b| a["path"].as_str().cmp(&b["path"].as_str()));
    let member_roles = members
        .iter()
        .map(|member| {
            (
                member["path"].as_str().unwrap().to_owned(),
                member["role"].as_str().unwrap().to_owned(),
            )
        })
        .collect::<BTreeMap<_, _>>();
    let graph = derive_graph(
        &members_root,
        &member_roles,
        bootstrap_path,
        request["manifest_base"]["hot_styles"].as_array().unwrap(),
    )?;
    for member in &mut members {
        let Some(path) = member["path"].as_str() else {
            continue;
        };
        if let Some(source_map) = graph.source_maps.get(path) {
            member["source_map"] = json!(source_map);
        }
    }
    let edges = graph
        .edges
        .into_iter()
        .map(|edge| json!({"from": edge.from, "to": edge.to, "kind": edge.kind}))
        .collect::<Vec<_>>();
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
        && frame::is_request_id(value.get("request_id"))
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
        if entries.len() != 1 || entries[0].file_name() != MARKER {
            return Err(OpError::new("invalid_request", "output root is not empty"));
        }
        let marker = &entries[0];
        let marker_metadata = fs::symlink_metadata(marker.path()).map_err(io_error)?;
        let expected = serde_jcs::to_vec(&json!({"root_id": value["id"], "v": 1}))
            .map_err(|error| OpError::new("internal", error.to_string()))?;
        let bytes = fs::read(marker.path()).map_err(io_error)?;
        if !marker_metadata.file_type().is_file()
            || marker_metadata.uid() != metadata.uid()
            || marker_metadata.dev() != metadata.dev()
            || marker_metadata.permissions().mode() & 0o777 != 0o600
            || bytes != expected
        {
            return Err(OpError::new("invalid_request", "invalid attempt marker"));
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
    if !frame::exact_keys(value, KEYS)
        || value["root_id"] != root.id
        || !digest(value["sha256"].as_str())
        || value["size"].as_u64().is_none()
        || !matches!(value["mode"].as_str(), Some("data" | "executable"))
    {
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

fn validate_manifest_base(value: &Value, allow_extension: bool) -> OpResult<()> {
    const KEYS: &[&str] = &[
        "rekindle_version",
        "application_id",
        "target",
        "build",
        "producer",
        "host_requirements",
        "hot_styles",
    ];
    if frame::exact_keys(value, KEYS)
        && value["target"] == "web"
        && value["rekindle_version"].as_str().is_some_and(valid_semver)
        && value["application_id"]
            .as_str()
            .is_some_and(valid_application_id)
        && valid_build(&value["build"])
        && (valid_canonical_web_producer(&value["producer"])
            || (allow_extension && valid_extension_producer(&value["producer"])))
        && value["host_requirements"] == json!({"secure_context": true, "webgpu": true})
        && relative_strings_sorted_unique(&value["hot_styles"])
    {
        Ok(())
    } else {
        Err(OpError::new("invalid_request", "invalid manifest base"))
    }
}

fn valid_build(build: &Value) -> bool {
    frame::exact_keys(
        build,
        &["build_key", "profile", "package", "binary", "features"],
    ) && digest(build["build_key"].as_str())
        && ["profile", "package", "binary"]
            .iter()
            .all(|key| build[*key].as_str().is_some_and(valid_cargo_identifier))
        && valid_feature_list(&build["features"])
}

fn valid_canonical_web_producer(producer: &Value) -> bool {
    frame::exact_keys(
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
    ) && producer["kind"] == "canonical_web"
        && producer["helper_protocol"] == 1
        && ["rustc", "cargo"]
            .iter()
            .all(|key| producer[*key].as_str().is_some_and(valid_manifest_string))
        && producer["rust_target"]
            .as_str()
            .is_some_and(valid_cargo_identifier)
        && producer["gpui_revision"]
            .as_str()
            .is_some_and(valid_gpui_revision)
        && digest(producer["compatibility_tuple_id"].as_str())
        && producer["wasm_bindgen"].as_str().is_some_and(valid_semver)
        && producer["helper_version"]
            .as_str()
            .is_some_and(valid_semver)
}

fn valid_extension_producer(producer: &Value) -> bool {
    frame::exact_keys(
        producer,
        &["kind", "backend_id", "backend_version", "options_digest"],
    ) && producer["kind"] == "extension"
        && producer["backend_id"]
            .as_str()
            .is_some_and(valid_backend_id)
        && producer["backend_version"]
            .as_str()
            .is_some_and(valid_backend_version)
        && digest(producer["options_digest"].as_str())
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
    validate_manifest_base(&base, true)?;
    let members = manifest["members"]
        .as_array()
        .ok_or_else(|| OpError::new("invalid_request", "invalid members"))?;
    let mut previous = None;
    let mut folded = BTreeSet::new();
    let mut member_paths = BTreeSet::new();
    let mut member_roles = BTreeMap::new();
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
        let role = member["role"].as_str().unwrap_or_default();
        let expected_metadata = member_metadata(role, path);
        if !frame::exact_keys(member, MEMBER_KEYS)
            || !relative(path)
            || previous.is_some_and(|prior: &str| prior >= path)
            || !folded.insert(case_fold_path(path))
            || !matches!(
                role,
                "bootstrap" | "javascript" | "wasm" | "css" | "asset" | "source_map"
            )
            || !digest(member["sha256"].as_str())
            || member["size"].as_u64().is_none()
            || expected_metadata.is_none()
            || expected_metadata
                .is_some_and(|(mime, cache)| member["mime"] != mime || member["cache"] != cache)
            || !(member["source_map"].is_null()
                || member["source_map"].as_str().is_some_and(relative))
        {
            return Err(OpError::new("invalid_request", "invalid manifest member"));
        }
        identity_members.push(json!({
            "path": member["path"], "role": member["role"],
            "sha256": member["sha256"], "size": member["size"]
        }));
        member_paths.insert(path.to_owned());
        member_roles.insert(path.to_owned(), member["role"].as_str().unwrap().to_owned());
        previous = Some(path);
    }

    validate_web_artifact_tree(root, &member_paths)?;
    validate_artifact_marker(root)?;

    for member in members {
        let path = member["path"].as_str().unwrap();
        let members_root = root.path.join("members");
        let member_path = members_root.join(path);
        if !no_symlink_below(&members_root, path)
            || !fs::symlink_metadata(&member_path)
                .is_ok_and(|metadata| metadata.file_type().is_file())
        {
            return Err(OpError::new("input_changed", "member type changed"));
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
    }
    let entry = manifest["entry"].as_str().unwrap_or_default();
    if !members.iter().any(|member| {
        member["path"] == entry && member["role"] == "bootstrap" && member["cache"] == "no_cache"
    }) {
        return Err(OpError::new("invalid_request", "invalid manifest entry"));
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
    let graph = derive_graph(
        &root.path.join("members"),
        &member_roles,
        entry,
        manifest["hot_styles"].as_array().unwrap(),
    )?;
    let expected_edges = graph
        .edges
        .iter()
        .map(|edge| json!({"from": edge.from, "to": edge.to, "kind": edge.kind}))
        .collect::<Vec<_>>();
    if manifest["edges"] != Value::Array(expected_edges) {
        return Err(OpError::new(
            "unsupported_import",
            "manifest graph does not match member bytes",
        ));
    }
    for member in members {
        let expected_source_map = graph.source_maps.get(member["path"].as_str().unwrap());
        if member["source_map"].as_str() != expected_source_map.map(String::as_str)
            && !(member["source_map"].is_null() && expected_source_map.is_none())
        {
            return Err(OpError::new(
                "unsupported_import",
                "manifest source map does not match member bytes",
            ));
        }
    }
    let bootstrap_edges = graph
        .edges
        .iter()
        .filter(|edge| edge.from == entry && edge.kind == "dynamic_import")
        .collect::<Vec<_>>();
    if bootstrap_edges.len() != 1
        || member_roles.get(&bootstrap_edges[0].to).map(String::as_str) != Some("javascript")
    {
        return Err(OpError::new(
            "unsupported_import",
            "bootstrap graph is incomplete",
        ));
    }
    for (path, role) in &member_roles {
        let required_kind = match role.as_str() {
            "wasm" => Some("wasm_url"),
            "source_map" => Some("source_map"),
            _ => None,
        };
        if required_kind.is_some_and(|kind| {
            !graph
                .edges
                .iter()
                .any(|edge| edge.to == *path && edge.kind == kind)
        }) {
            return Err(OpError::new(
                "unsupported_import",
                format!(
                    "member graph is incomplete: {path} requires {kind}",
                    kind = required_kind.unwrap()
                ),
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

fn validate_web_artifact_tree(root: &Root, member_paths: &BTreeSet<String>) -> OpResult<()> {
    let mut expected_files = BTreeSet::from([MARKER.to_owned(), MANIFEST.to_owned()]);
    let mut expected_directories = BTreeSet::from(["members".to_owned()]);

    for path in member_paths {
        expected_files.insert(format!("members/{path}"));

        let mut parent = Path::new(path).parent();
        while let Some(directory) = parent {
            if directory.as_os_str().is_empty() {
                break;
            }
            let directory = directory
                .to_str()
                .ok_or_else(|| OpError::new("input_changed", "artifact path is not UTF-8"))?;
            expected_directories.insert(format!("members/{directory}"));
            parent = Path::new(directory).parent();
        }
    }

    for entry in WalkDir::new(&root.path).min_depth(1).follow_links(false) {
        let entry = entry.map_err(|error| OpError::new("io_failed", error.to_string()))?;
        let relative = normalized_relative(entry.path(), &root.path)?;
        let file_type = entry.file_type();

        if expected_files.remove(&relative) {
            if !file_type.is_file() {
                return Err(OpError::new("input_changed", "artifact file type changed"));
            }
        } else if expected_directories.remove(&relative) {
            if !file_type.is_dir() {
                return Err(OpError::new(
                    "input_changed",
                    "artifact directory type changed",
                ));
            }
        } else {
            return Err(OpError::new(
                "input_changed",
                "artifact node closure changed",
            ));
        }
    }

    if expected_files.is_empty() && expected_directories.is_empty() {
        Ok(())
    } else {
        Err(OpError::new("input_changed", "artifact node is missing"))
    }
}

fn validate_artifact_marker(root: &Root) -> OpResult<()> {
    let path = root.path.join(MARKER);
    let root_metadata = fs::symlink_metadata(&root.path).map_err(io_error)?;
    let metadata = fs::symlink_metadata(&path).map_err(io_error)?;
    let bytes = fs::read(&path).map_err(io_error)?;
    let marker: Value = serde_json::from_slice(&bytes)
        .map_err(|_| OpError::new("input_changed", "invalid attempt marker"))?;
    let canonical =
        serde_jcs::to_vec(&marker).map_err(|error| OpError::new("internal", error.to_string()))?;

    if metadata.file_type().is_file()
        && metadata.uid() == root_metadata.uid()
        && metadata.dev() == root_metadata.dev()
        && metadata.permissions().mode() & 0o777 == 0o600
        && frame::exact_keys(&marker, &["root_id", "v"])
        && marker["v"] == 1
        && marker["root_id"] == root.id
        && canonical == bytes
    {
        Ok(())
    } else {
        Err(OpError::new("input_changed", "invalid attempt marker"))
    }
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
        && value.len() <= MAX_PATH_BYTES
        && value.nfc().eq(value.chars())
        && !value.chars().any(char::is_control)
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

fn valid_manifest_string(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= MAX_MANIFEST_STRING_BYTES
        && value.nfc().eq(value.chars())
        && !value.chars().any(char::is_control)
}

fn valid_semver(value: &str) -> bool {
    valid_manifest_string(value) && Version::parse(value).is_ok()
}

fn valid_application_id(value: &str) -> bool {
    let bytes = value.as_bytes();
    (1..=128).contains(&bytes.len())
        && bytes[0].is_ascii_lowercase()
        && bytes[1..].iter().all(|byte| {
            byte.is_ascii_lowercase() || byte.is_ascii_digit() || matches!(byte, b'_' | b'-')
        })
}

fn valid_backend_id(value: &str) -> bool {
    let bytes = value.as_bytes();
    (1..=128).contains(&bytes.len())
        && bytes[0].is_ascii_lowercase()
        && bytes[1..].iter().all(|byte| {
            byte.is_ascii_lowercase() || byte.is_ascii_digit() || matches!(byte, b'_' | b'.' | b'-')
        })
}

fn valid_backend_version(value: &str) -> bool {
    (1..=128).contains(&value.len()) && value.is_ascii()
}

fn relative_strings_sorted_unique(value: &Value) -> bool {
    value.as_array().is_some_and(|values| {
        values.windows(2).all(|pair| {
            pair[0]
                .as_str()
                .zip(pair[1].as_str())
                .is_some_and(|(left, right)| left < right)
        }) && values
            .iter()
            .all(|value| value.as_str().is_some_and(relative))
    })
}

fn valid_feature_list(value: &Value) -> bool {
    let Some(values) = value.as_array() else {
        return false;
    };

    values.len() <= 128
        && values.windows(2).all(|pair| {
            pair[0]
                .as_str()
                .zip(pair[1].as_str())
                .is_some_and(|(left, right)| left < right)
        })
        && values
            .iter()
            .all(|value| value.as_str().is_some_and(valid_cargo_identifier))
        && values
            .iter()
            .filter_map(Value::as_str)
            .try_fold(0_usize, |total, value| total.checked_add(value.len()))
            .is_some_and(|total| total <= 8_192)
}

fn valid_cargo_identifier(value: &str) -> bool {
    (1..=128).contains(&value.len()) && value.bytes().all(|byte| (0x20..=0x7e).contains(&byte))
}

fn valid_gpui_revision(value: &str) -> bool {
    (40..=64).contains(&value.len())
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn case_fold_path(value: &str) -> String {
    value.case_fold().collect()
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

fn member_metadata(role: &str, path: &str) -> Option<(&'static str, &'static str)> {
    let folded = case_fold_path(path);
    let extension = Path::new(&folded)
        .extension()
        .and_then(|extension| extension.to_str());

    match role {
        "bootstrap" if extension == Some("js") => {
            Some(("text/javascript; charset=utf-8", "no_cache"))
        }
        "javascript" if extension == Some("js") => {
            Some(("text/javascript; charset=utf-8", "immutable"))
        }
        "wasm" if extension == Some("wasm") => Some(("application/wasm", "immutable")),
        "css" if extension == Some("css") => Some(("text/css; charset=utf-8", "immutable")),
        "source_map" if extension == Some("map") => {
            Some(("application/json; charset=utf-8", "immutable"))
        }
        "asset" if !matches!(extension, Some("js" | "wasm" | "css" | "map")) => {
            Some((asset_mime(extension), "immutable"))
        }
        _ => None,
    }
}

fn asset_mime(extension: Option<&str>) -> &'static str {
    match extension {
        Some("png") => "image/png",
        Some("jpg" | "jpeg") => "image/jpeg",
        Some("gif") => "image/gif",
        Some("webp") => "image/webp",
        Some("avif") => "image/avif",
        Some("svg") => "image/svg+xml",
        Some("ico") => "image/x-icon",
        Some("woff") => "font/woff",
        Some("woff2") => "font/woff2",
        Some("ttf") => "font/ttf",
        Some("otf") => "font/otf",
        Some("txt") => "text/plain; charset=utf-8",
        Some("json") => "application/json; charset=utf-8",
        _ => "application/octet-stream",
    }
}

fn io_error(error: std::io::Error) -> OpError {
    OpError::new("io_failed", error.to_string())
}

fn device_identity(device: u64, special_device: u64) -> u64 {
    device * 4_294_967_296 + special_device
}

#[cfg(test)]
mod graph_tests {
    use super::*;

    #[test]
    fn discovers_javascript_reference_forms() {
        let source = br#"
            import "./static.js";
            export { value } from "./exported.js";
            const lazy = import("./lazy.js");
            const wasm = new URL("app_bg.wasm", import.meta.url);
            //# sourceMappingURL=app.js.map
        "#;
        let references = javascript_references(source).unwrap();
        assert_eq!(
            references,
            vec![
                ("./static.js".into(), "esm_import", true),
                ("./exported.js".into(), "esm_import", true),
                ("./lazy.js".into(), "dynamic_import", true),
                ("app_bg.wasm".into(), "wasm_url", false),
                ("app.js.map".into(), "source_map", false),
            ]
        );
    }

    #[test]
    fn discovers_css_reference_forms_without_scanning_comments_or_strings() {
        let source = br#"
            @import "./theme.css";
            @import url("https://cdn.example/base.css");
            .hero { background: url(./image.png); content: "url(./ignored.png)"; }
            /* url("./also-ignored.png") */
            /*# sourceMappingURL=app.css.map */
        "#;
        let references = css_references(source).unwrap();
        assert_eq!(
            references,
            vec![
                ("./theme.css".into(), "css_url", false),
                ("https://cdn.example/base.css".into(), "css_url", false),
                ("./image.png".into(), "asset_url", false),
                ("app.css.map".into(), "source_map", false),
            ]
        );
    }

    #[test]
    fn admits_only_relative_members_and_explicit_https_urls() {
        assert_eq!(
            resolve_reference("modules/app.js", "./nested.js", true).unwrap(),
            "modules/nested.js"
        );
        assert_eq!(
            resolve_reference("styles/app.css", "https://cdn.example/a.png", false).unwrap(),
            "https://cdn.example/a.png"
        );
        for forbidden in [
            "react",
            "npm:react",
            "../escape.js",
            "data:text/plain,x",
            "javascript:alert(1)",
            "file:///tmp/member",
            "/absolute.js",
        ] {
            assert!(resolve_reference("app.js", forbidden, true).is_err());
        }
    }

    #[test]
    fn enforces_exact_manifest_identifier_and_feature_bounds() {
        assert!(valid_application_id("sample_app"));
        assert!(!valid_application_id("é"));
        assert!(valid_backend_id("example.backend"));
        assert!(!valid_backend_id("INVALID"));
        assert!(valid_backend_version("release-1"));
        assert!(!valid_backend_version("é"));
        assert!(valid_feature_list(&json!([])));

        let too_many = (0..129)
            .map(|number| Value::String(format!("f{number:03}")))
            .collect::<Vec<_>>();
        assert!(!valid_feature_list(&Value::Array(too_many)));

        let oversized = (0..65)
            .map(|number| Value::String(format!("{}{number:04}", "a".repeat(124))))
            .collect::<Vec<_>>();
        assert!(!valid_feature_list(&Value::Array(oversized)));
        assert!(!valid_cargo_identifier("é"));
        assert!(!valid_cargo_identifier(&"a".repeat(129)));
        assert!(valid_gpui_revision(&"a".repeat(40)));
        assert!(valid_gpui_revision(&"f".repeat(64)));
        assert!(!valid_gpui_revision(&"a".repeat(39)));
        assert!(!valid_gpui_revision(&"A".repeat(40)));
        assert!(digest(Some(&"a".repeat(64))));
        assert!(!digest(Some(&"A".repeat(64))));
    }
}
