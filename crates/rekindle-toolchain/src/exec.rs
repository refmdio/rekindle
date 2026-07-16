use crate::frame;
use serde_json::{Map, Value, json};
use std::io::Read;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::mpsc::{self, Receiver, Sender};
use std::thread;
use std::time::{Duration, Instant};

enum StreamEvent {
    Data(&'static str, Vec<u8>),
    Discarded(&'static str, u64),
    Eof(&'static str),
    Error(String),
}

struct StreamState {
    stdout_sequence: u64,
    stderr_sequence: u64,
    stdout_bytes: u64,
    stderr_bytes: u64,
    discarded_stdout: u64,
    discarded_stderr: u64,
    stdout_eof: bool,
    stderr_eof: bool,
}

struct ExitReport<'a> {
    outcome: &'a str,
    code: Option<i32>,
    signal: Option<i32>,
    cleanup: &'a str,
    stdout_bytes: u64,
    stderr_bytes: u64,
    discarded_stdout: u64,
    discarded_stderr: u64,
}

const MAX_STREAM_BYTES: u64 = 1_048_576;

pub fn run<R: Read>(mut input: R) -> Result<(), String> {
    enable_subreaper()?;
    let spawn = frame::read(&mut input)?.ok_or_else(|| "missing spawn request".to_string())?;
    if !spawn.payload.is_empty() {
        return Err("spawn payload must be empty".into());
    }
    let request = validate_spawn(&spawn.header)?;
    let request_id = request["request_id"].as_str().unwrap().to_owned();

    let mut command = Command::new(request["executable"]["value"].as_str().unwrap());
    command
        .args(
            request["argv"]
                .as_array()
                .unwrap()
                .iter()
                .map(|v| v.as_str().unwrap()),
        )
        .current_dir(request["cwd"].as_str().unwrap())
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if request["env_mode"] == "replace" {
        command.env_clear();
    }
    for name in request["env_unset"].as_array().unwrap() {
        command.env_remove(name.as_str().unwrap());
    }
    for pair in request["env_set"].as_array().unwrap() {
        let pair = pair.as_array().unwrap();
        command.env(pair[0].as_str().unwrap(), pair[1].as_str().unwrap());
    }
    unsafe {
        command.pre_exec(|| {
            if libc::setsid() == -1 {
                return Err(std::io::Error::last_os_error());
            }

            #[cfg(target_os = "linux")]
            {
                if libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL, 0, 0, 0) == -1 {
                    return Err(std::io::Error::last_os_error());
                }
                if libc::getppid() == 1 {
                    return Err(std::io::Error::other(
                        "helper parent died before child ownership transfer",
                    ));
                }
            }

            Ok(())
        });
    }

    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(_) => {
            write_exit(
                &request_id,
                &ExitReport {
                    outcome: "spawn_failed",
                    code: None,
                    signal: None,
                    cleanup: "confirmed",
                    stdout_bytes: 0,
                    stderr_bytes: 0,
                    discarded_stdout: 0,
                    discarded_stderr: 0,
                },
            )?;
            return Ok(());
        }
    };
    let pgid = child.id() as i32;
    frame::write(
        &mut std::io::stdout().lock(),
        &json!({
            "v": 1, "type": "started", "request_id": request_id,
            "payload_len": 0, "pid": child.id(), "process_group": child.id()
        }),
        &[],
    )?;

    let (sender, receiver) = mpsc::channel();
    stream_thread(child.stdout.take().unwrap(), "stdout", sender.clone());
    stream_thread(child.stderr.take().unwrap(), "stderr", sender);
    let mut streams = StreamState {
        stdout_sequence: 0,
        stderr_sequence: 0,
        stdout_bytes: 0,
        stderr_bytes: 0,
        discarded_stdout: 0,
        discarded_stderr: 0,
        stdout_eof: false,
        stderr_eof: false,
    };
    let terminate_grace = Duration::from_millis(request["terminate_grace_ms"].as_u64().unwrap());
    let kill_grace = Duration::from_millis(request["kill_grace_ms"].as_u64().unwrap());
    let mut status = None;
    let mut cancelled = false;
    let mut cleanup = "confirmed";

    loop {
        drain_streams(&receiver, &request_id, &mut streams)?;
        if status.is_none() {
            status = child
                .try_wait()
                .map_err(|error| format!("wait failed: {error}"))?;
            if status.is_some() {
                cleanup = cleanup_group(pgid, terminate_grace, kill_grace);
            }
        }
        if status.is_some() && streams.stdout_eof && streams.stderr_eof {
            break;
        }

        if !cancelled && stdin_ready()? {
            match frame::read(&mut input)? {
                Some(cancel) => {
                    validate_cancel(&cancel, &request_id)?;
                    cleanup = terminate(&mut child, pgid, terminate_grace, kill_grace);
                    status = child.try_wait().map_err(|error| error.to_string())?;
                    cancelled = true;
                }
                None => {
                    cleanup = terminate(&mut child, pgid, terminate_grace, kill_grace);
                    status = child.try_wait().map_err(|error| error.to_string())?;
                    cancelled = true;
                }
            }
        }
        thread::sleep(Duration::from_millis(5));
    }

    let status = match status {
        Some(status) => status,
        None => child
            .wait()
            .map_err(|error| format!("wait failed: {error}"))?,
    };
    let (outcome, code, signal) = classify_status(status);
    write_exit(
        &request_id,
        &ExitReport {
            outcome,
            code,
            signal,
            cleanup,
            stdout_bytes: streams.stdout_bytes,
            stderr_bytes: streams.stderr_bytes,
            discarded_stdout: streams.discarded_stdout,
            discarded_stderr: streams.discarded_stderr,
        },
    )
}

fn validate_spawn(value: &Value) -> Result<&Map<String, Value>, String> {
    const KEYS: &[&str] = &[
        "v",
        "type",
        "request_id",
        "payload_len",
        "executable",
        "argv",
        "cwd",
        "env_mode",
        "env_set",
        "env_unset",
        "terminate_grace_ms",
        "kill_grace_ms",
    ];
    if !frame::exact_keys(value, KEYS) {
        return Err("invalid spawn fields".into());
    }
    let object = value.as_object().unwrap();
    let executable = object["executable"]
        .as_object()
        .ok_or("invalid executable")?;
    let executable_keys = executable.keys().map(String::as_str).collect::<Vec<_>>();
    let executable_path = executable
        .get("value")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if object["type"] != "spawn"
        || object["payload_len"] != 0
        || executable_keys.len() != 2
        || executable.get("kind") != Some(&Value::String("path".into()))
        || !absolute(executable_path)
        || !absolute(object["cwd"].as_str().unwrap_or_default())
        || !qualified_executable(executable_path)
        || !qualified_directory(object["cwd"].as_str().unwrap_or_default())
        || !strings(&object["argv"])
        || !matches!(object["env_mode"].as_str(), Some("inherit" | "replace"))
        || !environment(&object["env_set"], &object["env_unset"])
        || object["terminate_grace_ms"].as_u64().unwrap_or(0) == 0
        || object["kill_grace_ms"].as_u64().unwrap_or(0) == 0
    {
        return Err("invalid spawn request".into());
    }
    Ok(object)
}

fn validate_cancel(frame_value: &frame::Frame, request_id: &str) -> Result<(), String> {
    const KEYS: &[&str] = &["v", "type", "request_id", "payload_len", "reason"];
    let value = &frame_value.header;
    if !frame_value.payload.is_empty()
        || !frame::exact_keys(value, KEYS)
        || value["type"] != "cancel"
        || value["request_id"] != request_id
        || value["payload_len"] != 0
        || !matches!(
            value["reason"].as_str(),
            Some("obsolete" | "timeout" | "shutdown" | "caller")
        )
    {
        return Err("invalid cancel".into());
    }
    Ok(())
}

fn stream_thread<R: Read + Send + 'static>(
    mut reader: R,
    kind: &'static str,
    sender: Sender<StreamEvent>,
) {
    thread::spawn(move || {
        let mut buffer = vec![0_u8; 64 * 1024];
        let mut emitted = 0_u64;
        loop {
            match reader.read(&mut buffer) {
                Ok(0) => {
                    let _ = sender.send(StreamEvent::Eof(kind));
                    break;
                }
                Ok(size) => {
                    let available = MAX_STREAM_BYTES.saturating_sub(emitted) as usize;
                    let retained = size.min(available);
                    if retained > 0 {
                        emitted += retained as u64;
                        if sender
                            .send(StreamEvent::Data(kind, buffer[..retained].to_vec()))
                            .is_err()
                        {
                            break;
                        }
                    }
                    if retained < size
                        && sender
                            .send(StreamEvent::Discarded(kind, (size - retained) as u64))
                            .is_err()
                    {
                        break;
                    }
                }
                Err(error) => {
                    let _ = sender.send(StreamEvent::Error(error.to_string()));
                    break;
                }
            }
        }
    });
}

fn drain_streams(
    receiver: &Receiver<StreamEvent>,
    request_id: &str,
    state: &mut StreamState,
) -> Result<(), String> {
    while let Ok(event) = receiver.try_recv() {
        match event {
            StreamEvent::Data(kind, bytes) => write_stream(request_id, kind, false, bytes, state)?,
            StreamEvent::Discarded("stdout", bytes) => state.discarded_stdout += bytes,
            StreamEvent::Discarded("stderr", bytes) => state.discarded_stderr += bytes,
            StreamEvent::Discarded(_, _) => return Err("invalid stream kind".into()),
            StreamEvent::Eof(kind) => write_stream(request_id, kind, true, Vec::new(), state)?,
            StreamEvent::Error(error) => return Err(format!("stream read failed: {error}")),
        }
    }
    Ok(())
}

fn write_stream(
    request_id: &str,
    kind: &str,
    eof: bool,
    bytes: Vec<u8>,
    state: &mut StreamState,
) -> Result<(), String> {
    let (sequence, total, ended) = if kind == "stdout" {
        (
            &mut state.stdout_sequence,
            &mut state.stdout_bytes,
            &mut state.stdout_eof,
        )
    } else {
        (
            &mut state.stderr_sequence,
            &mut state.stderr_bytes,
            &mut state.stderr_eof,
        )
    };
    *total += bytes.len() as u64;
    frame::write(
        &mut std::io::stdout().lock(),
        &json!({
            "v": 1, "type": kind, "request_id": request_id,
            "payload_len": bytes.len(), "sequence": *sequence, "eof": eof
        }),
        &bytes,
    )?;
    *sequence += 1;
    *ended = eof;
    Ok(())
}

fn terminate(child: &mut Child, pgid: i32, term: Duration, kill: Duration) -> &'static str {
    signal_group(pgid, libc::SIGTERM);
    if wait_child(child, term) {
        return cleanup_group(pgid, Duration::ZERO, kill);
    }
    signal_group(pgid, libc::SIGKILL);
    let reaped = wait_child(child, kill);
    if reaped && group_absent(pgid) {
        "confirmed"
    } else {
        "uncertain"
    }
}

fn cleanup_group(pgid: i32, term: Duration, kill: Duration) -> &'static str {
    if group_absent(pgid) {
        return "confirmed";
    }
    signal_group(pgid, libc::SIGTERM);
    if wait_group_absent(pgid, term) {
        return "confirmed";
    }
    signal_group(pgid, libc::SIGKILL);
    if wait_group_absent(pgid, kill) {
        "confirmed"
    } else {
        "uncertain"
    }
}

fn wait_child(child: &mut Child, duration: Duration) -> bool {
    let deadline = Instant::now() + duration;
    loop {
        if child.try_wait().ok().flatten().is_some() {
            return true;
        }
        if Instant::now() >= deadline {
            return false;
        }
        thread::sleep(Duration::from_millis(5));
    }
}

fn wait_group_absent(pgid: i32, duration: Duration) -> bool {
    let deadline = Instant::now() + duration;
    loop {
        reap_descendants();
        if group_absent(pgid) {
            return true;
        }
        if Instant::now() >= deadline {
            return false;
        }
        thread::sleep(Duration::from_millis(5));
    }
}

#[cfg(target_os = "linux")]
fn enable_subreaper() -> Result<(), String> {
    let result = unsafe { libc::prctl(libc::PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) };
    if result == 0 {
        Ok(())
    } else {
        Err(format!(
            "failed to enable descendant reaping: {}",
            std::io::Error::last_os_error()
        ))
    }
}

#[cfg(not(target_os = "linux"))]
fn enable_subreaper() -> Result<(), String> {
    Ok(())
}

fn reap_descendants() {
    loop {
        let mut status = 0;
        let pid = unsafe { libc::waitpid(-1, &mut status, libc::WNOHANG) };
        if pid <= 0 {
            break;
        }
    }
}

fn signal_group(pgid: i32, signal: i32) {
    unsafe {
        libc::kill(-pgid, signal);
    }
}

fn group_absent(pgid: i32) -> bool {
    let result = unsafe { libc::kill(-pgid, 0) };
    result == -1 && std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH)
}

fn stdin_ready() -> Result<bool, String> {
    let mut descriptor = libc::pollfd {
        fd: 0,
        events: libc::POLLIN | libc::POLLHUP,
        revents: 0,
    };
    let result = unsafe { libc::poll(&mut descriptor, 1, 0) };
    if result < 0 {
        Err(std::io::Error::last_os_error().to_string())
    } else {
        Ok(result > 0 && descriptor.revents != 0)
    }
}

fn classify_status(status: ExitStatus) -> (&'static str, Option<i32>, Option<i32>) {
    if let Some(code) = status.code() {
        ("exited", Some(code), None)
    } else {
        ("signaled", None, status.signal())
    }
}

fn write_exit(request_id: &str, report: &ExitReport<'_>) -> Result<(), String> {
    frame::write(
        &mut std::io::stdout().lock(),
        &json!({
            "v": 1, "type": "exit", "request_id": request_id, "payload_len": 0,
            "outcome": report.outcome, "code": report.code, "signal": report.signal,
            "cleanup": report.cleanup, "stdout_bytes": report.stdout_bytes,
            "stderr_bytes": report.stderr_bytes,
            "discarded_stdout": report.discarded_stdout,
            "discarded_stderr": report.discarded_stderr
        }),
        &[],
    )
}

fn absolute(value: &str) -> bool {
    value.starts_with('/') && !value.as_bytes().contains(&0)
}

fn strings(value: &Value) -> bool {
    value.as_array().is_some_and(|values| {
        values
            .iter()
            .all(|v| v.as_str().is_some_and(|s| !s.as_bytes().contains(&0)))
    })
}

fn environment(set: &Value, unset: &Value) -> bool {
    let Some(set) = set.as_array() else {
        return false;
    };
    let Some(unset) = unset.as_array() else {
        return false;
    };
    let mut names = std::collections::BTreeSet::new();
    for pair in set {
        let Some(pair) = pair.as_array() else {
            return false;
        };
        if pair.len() != 2
            || !valid_env(pair[0].as_str())
            || pair[1].as_str().is_none()
            || !names.insert(pair[0].as_str().unwrap())
        {
            return false;
        }
    }
    let mut unset_names = std::collections::BTreeSet::new();
    unset.iter().all(|name| {
        valid_env(name.as_str())
            && !names.contains(name.as_str().unwrap())
            && unset_names.insert(name.as_str().unwrap())
    })
}

fn qualified_executable(path: &str) -> bool {
    let Ok(metadata) = std::fs::symlink_metadata(path) else {
        return false;
    };
    metadata.file_type().is_file()
        && metadata.permissions().mode() & 0o100 != 0
        && no_symlink_components(path)
}

fn qualified_directory(path: &str) -> bool {
    std::fs::symlink_metadata(path)
        .is_ok_and(|metadata| metadata.file_type().is_dir() && no_symlink_components(path))
}

fn no_symlink_components(path: &str) -> bool {
    let mut current = std::path::PathBuf::new();
    for component in std::path::Path::new(path).components() {
        current.push(component.as_os_str());
        if matches!(component, std::path::Component::RootDir) {
            continue;
        }
        if !std::fs::symlink_metadata(&current)
            .is_ok_and(|metadata| !metadata.file_type().is_symlink())
        {
            return false;
        }
    }
    true
}

fn valid_env(value: Option<&str>) -> bool {
    value.is_some_and(|value| {
        let mut chars = value.chars();
        chars
            .next()
            .is_some_and(|c| c == '_' || c.is_ascii_alphabetic())
            && chars.all(|c| c == '_' || c.is_ascii_alphanumeric())
            && value.len() <= 128
    })
}
