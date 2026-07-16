use std::fs::File;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::fd::{FromRawFd, OwnedFd};
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::thread;
use std::time::{Duration, Instant};

pub struct Exit {
    pub outcome: &'static str,
    pub code: Option<i32>,
    pub signal: Option<i32>,
    pub cleanup: &'static str,
}

pub enum SpawnResult {
    Started(OwnedProcess),
    Failed,
}

pub struct OwnedProcess {
    pub pid: u32,
    pub stdout: File,
    pub stderr: File,
    control: File,
    exit: Receiver<Result<Exit, String>>,
}

impl OwnedProcess {
    pub fn cancel(&mut self) -> Result<(), String> {
        self.control
            .write_all(b"C")
            .and_then(|_| self.control.flush())
            .map_err(|error| format!("guardian cancel failed: {error}"))
    }

    pub fn try_exit(&self) -> Result<Option<Exit>, String> {
        match self.exit.try_recv() {
            Ok(result) => result.map(Some),
            Err(mpsc::TryRecvError::Empty) => Ok(None),
            Err(mpsc::TryRecvError::Disconnected) => {
                Err("guardian exited without a terminal report".into())
            }
        }
    }
}

pub fn spawn(
    mut command: Command,
    terminate_grace: Duration,
    kill_grace: Duration,
) -> Result<SpawnResult, String> {
    let (stdout_read, stdout_write) = pipe()?;
    let (stderr_read, stderr_write) = pipe()?;
    let (control_read, control_write) = pipe()?;
    let (status_read, status_write) = pipe()?;

    let guardian_pid = unsafe { libc::fork() };
    if guardian_pid < 0 {
        return Err(format!(
            "guardian fork failed: {}",
            std::io::Error::last_os_error()
        ));
    }

    if guardian_pid == 0 {
        drop(stdout_read);
        drop(stderr_read);
        drop(control_write);
        drop(status_read);
        close_protocol_descriptors();

        let status = guardian_main(
            &mut command,
            stdout_write,
            stderr_write,
            File::from(control_read),
            status_write,
            terminate_grace,
            kill_grace,
        );
        unsafe { libc::_exit(status) };
    }

    drop(stdout_write);
    drop(stderr_write);
    drop(control_read);
    drop(status_write);

    let stdout = File::from(stdout_read);
    let stderr = File::from(stderr_read);
    let control = File::from(control_write);
    let mut status = BufReader::new(File::from(status_read));
    let mut started = String::new();
    status
        .read_line(&mut started)
        .map_err(|error| format!("guardian start read failed: {error}"))?;

    if started == "F\n" {
        reap_guardian(guardian_pid);
        return Ok(SpawnResult::Failed);
    }

    let pid = started
        .strip_prefix("S ")
        .and_then(|value| value.trim().parse::<u32>().ok())
        .ok_or_else(|| "guardian returned an invalid start report".to_string())?;
    let (sender, receiver) = mpsc::channel();
    thread::spawn(move || {
        let result = read_exit(&mut status);
        reap_guardian(guardian_pid);
        let _ = sender.send(result);
    });

    Ok(SpawnResult::Started(OwnedProcess {
        pid,
        stdout,
        stderr,
        control,
        exit: receiver,
    }))
}

fn guardian_main(
    command: &mut Command,
    stdout: OwnedFd,
    stderr: OwnedFd,
    mut control: File,
    status: OwnedFd,
    terminate_grace: Duration,
    kill_grace: Duration,
) -> i32 {
    let mut status = File::from(status);
    command
        .stdout(Stdio::from(stdout))
        .stderr(Stdio::from(stderr));
    unsafe {
        command.pre_exec(|| {
            if libc::setsid() == -1 {
                Err(std::io::Error::last_os_error())
            } else {
                Ok(())
            }
        });
    }

    if enable_subreaper().is_err() {
        let _ = status.write_all(b"F\n");
        return 2;
    }

    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(_) => {
            let _ = status.write_all(b"F\n");
            return 0;
        }
    };
    let pgid = child.id() as i32;
    if writeln!(status, "S {}", child.id()).is_err() || status.flush().is_err() {
        terminate(&mut child, pgid, terminate_grace, kill_grace);
        return 2;
    }

    let (exit_status, cleanup) = loop {
        match child.try_wait() {
            Ok(Some(exit_status)) => {
                let cleanup = cleanup_group(pgid, terminate_grace, kill_grace);
                break (exit_status, cleanup);
            }
            Ok(None) => {}
            Err(_) => {
                terminate(&mut child, pgid, terminate_grace, kill_grace);
                return 2;
            }
        }

        match control_event(&mut control) {
            Ok(Control::None) => thread::sleep(Duration::from_millis(5)),
            Ok(Control::Cancel | Control::OwnerDied) | Err(_) => {
                let cleanup = terminate(&mut child, pgid, terminate_grace, kill_grace);
                let exit_status = match child.try_wait().ok().flatten() {
                    Some(exit_status) => exit_status,
                    None => return 2,
                };
                break (exit_status, cleanup);
            }
        }
    };

    let (outcome, code, signal) = if let Some(code) = exit_status.code() {
        ("exited", code, -1)
    } else {
        ("signaled", -1, exit_status.signal().unwrap_or(-1))
    };
    if writeln!(status, "E {outcome} {code} {signal} {cleanup}").is_err() || status.flush().is_err()
    {
        2
    } else {
        0
    }
}

enum Control {
    None,
    Cancel,
    OwnerDied,
}

fn control_event(control: &mut File) -> Result<Control, String> {
    let mut descriptor = libc::pollfd {
        fd: std::os::fd::AsRawFd::as_raw_fd(control),
        events: libc::POLLIN | libc::POLLHUP,
        revents: 0,
    };
    let result = unsafe { libc::poll(&mut descriptor, 1, 0) };
    if result < 0 {
        return Err(std::io::Error::last_os_error().to_string());
    }
    if result == 0 {
        return Ok(Control::None);
    }
    if descriptor.revents & libc::POLLIN != 0 {
        let mut byte = [0_u8; 1];
        return match Read::read(control, &mut byte) {
            Ok(0) => Ok(Control::OwnerDied),
            Ok(_) => Ok(Control::Cancel),
            Err(error) => Err(error.to_string()),
        };
    }
    if descriptor.revents & libc::POLLHUP != 0 {
        Ok(Control::OwnerDied)
    } else {
        Err("guardian control pipe failed".into())
    }
}

fn read_exit(reader: &mut impl BufRead) -> Result<Exit, String> {
    let mut line = String::new();
    reader
        .read_line(&mut line)
        .map_err(|error| format!("guardian exit read failed: {error}"))?;
    let fields = line.split_whitespace().collect::<Vec<_>>();
    if fields.len() != 5 || fields[0] != "E" {
        return Err("guardian returned an invalid exit report".into());
    }
    let outcome = match fields[1] {
        "exited" => "exited",
        "signaled" => "signaled",
        _ => return Err("guardian returned an invalid outcome".into()),
    };
    let code = parse_optional(fields[2])?;
    let signal = parse_optional(fields[3])?;
    let cleanup = match fields[4] {
        "confirmed" => "confirmed",
        "uncertain" => "uncertain",
        _ => return Err("guardian returned an invalid cleanup result".into()),
    };
    Ok(Exit {
        outcome,
        code,
        signal,
        cleanup,
    })
}

fn parse_optional(value: &str) -> Result<Option<i32>, String> {
    let parsed = value
        .parse::<i32>()
        .map_err(|_| "guardian returned an invalid status value".to_string())?;
    Ok((parsed >= 0).then_some(parsed))
}

fn terminate(
    child: &mut Child,
    pgid: i32,
    terminate_grace: Duration,
    kill_grace: Duration,
) -> &'static str {
    signal_group(pgid, libc::SIGTERM);
    if wait_child(child, terminate_grace) {
        return cleanup_group(pgid, Duration::ZERO, kill_grace);
    }
    signal_group(pgid, libc::SIGKILL);
    if wait_terminated(child, pgid, kill_grace) {
        "confirmed"
    } else {
        "uncertain"
    }
}

fn cleanup_group(pgid: i32, terminate_grace: Duration, kill_grace: Duration) -> &'static str {
    if group_absent(pgid) {
        return "confirmed";
    }
    signal_group(pgid, libc::SIGTERM);
    if wait_group_absent(pgid, terminate_grace) {
        return "confirmed";
    }
    signal_group(pgid, libc::SIGKILL);
    if wait_group_absent(pgid, kill_grace) {
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

fn wait_terminated(child: &mut Child, pgid: i32, duration: Duration) -> bool {
    let deadline = Instant::now() + duration;
    let mut leader_reaped = false;

    loop {
        if !leader_reaped {
            leader_reaped = child.try_wait().ok().flatten().is_some();
        }
        reap_descendants();
        if leader_reaped && group_absent(pgid) {
            return true;
        }
        if Instant::now() >= deadline {
            return false;
        }
        thread::sleep(Duration::from_millis(5));
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

#[cfg(target_os = "linux")]
fn enable_subreaper() -> Result<(), String> {
    let result = unsafe { libc::prctl(libc::PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) };
    if result == 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error().to_string())
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

fn pipe() -> Result<(OwnedFd, OwnedFd), String> {
    let mut descriptors = [0_i32; 2];
    if unsafe { libc::pipe(descriptors.as_mut_ptr()) } == -1 {
        Err(std::io::Error::last_os_error().to_string())
    } else {
        Ok(unsafe {
            (
                OwnedFd::from_raw_fd(descriptors[0]),
                OwnedFd::from_raw_fd(descriptors[1]),
            )
        })
    }
}

fn close_protocol_descriptors() {
    unsafe {
        libc::close(libc::STDIN_FILENO);
        libc::close(libc::STDOUT_FILENO);
        libc::close(libc::STDERR_FILENO);
    }
}

fn reap_guardian(pid: libc::pid_t) {
    let mut status = 0;
    unsafe {
        libc::waitpid(pid, &mut status, 0);
    }
}
