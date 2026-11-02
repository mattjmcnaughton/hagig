//! Controlled lifecycle slice. No inference engine, user audio files or downloads.

use crate::launcher::{NetworkIsolation, PlatformLauncher, WorkerExecutable};
use crate::supervisor::Supervisor;
use serde::Deserialize;
use serde_json::json;
use std::fs::{self, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::process::{Command, Stdio};
use std::sync::mpsc::{self, Receiver, Sender, SyncSender};
use std::time::{Duration, Instant};

mod paths;
use paths::{connect, runtime, validate};

const CONTROL: usize = 65_536;
const AUDIO: usize = 262_144;
const TOTAL_AUDIO: usize = 19_200_000;
const TICK: Duration = Duration::from_millis(5);
type SafeResult<T> = Result<T, &'static str>;

/// Control schema rejects unknown fields; request IDs are bounded opaque tokens.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Control {
    version: u32,
    #[serde(rename = "type")]
    kind: String,
    #[serde(default)]
    request_id: Option<String>,
    /// Only the explicitly selected controlled fake service accepts this field.
    #[serde(default)]
    fake_action: Option<String>,
    #[serde(default)]
    fake_pause_delivery: Option<bool>,
    #[serde(default)]
    fake_pause_completion: Option<bool>,
    #[serde(default)]
    fake_advance_seconds: Option<u32>,
}

/// Only explicit __serve --fake-worker --fake-test-controls enables these effects.
/// Virtual time affects request/idle deadlines only; ordinary durations stay fixed.
#[derive(Default)]
struct FakeTests {
    clock: Option<Instant>,
    advance: Duration,
    pause_delivery: bool,
    pause_completion: bool,
    pending_results: usize,
    pending_completions: usize,
}

impl FakeTests {
    fn now(&self) -> Instant {
        self.clock.unwrap_or_else(Instant::now) + self.advance
    }
}

fn packet(value: &serde_json::Value) -> Vec<u8> {
    let bytes = serde_json::to_vec(value).expect("bounded response");
    let mut frame = vec![1];
    frame.extend_from_slice(&(bytes.len() as u32).to_be_bytes());
    frame.extend(bytes);
    frame
}

fn read_before(stream: &mut UnixStream, bytes: &mut [u8], deadline: Instant) -> SafeResult<()> {
    let mut offset = 0;
    while offset < bytes.len() {
        let remaining = deadline
            .checked_duration_since(Instant::now())
            .ok_or("connection_timeout")?;
        stream
            .set_read_timeout(Some(remaining))
            .map_err(|_| "connection_failed")?;
        match stream.read(&mut bytes[offset..]) {
            Ok(0) => return Err("connection_failed"),
            Ok(n) => offset += n,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => (),
            Err(_) => return Err("connection_failed"),
        }
    }
    Ok(())
}

fn exchange(stream: &mut UnixStream, kind: &str) -> SafeResult<serde_json::Value> {
    let deadline = Instant::now() + Duration::from_secs(5);
    let value = if matches!(kind, "begin" | "end_audio") {
        json!({"version":1,"type":kind,"request_id":"cli"})
    } else {
        json!({"version":1,"type":kind})
    };
    let outgoing = packet(&value);
    let mut offset = 0;
    while offset < outgoing.len() {
        let remaining = deadline
            .checked_duration_since(Instant::now())
            .ok_or("connection_timeout")?;
        stream
            .set_write_timeout(Some(remaining))
            .map_err(|_| "connection_failed")?;
        match stream.write(&outgoing[offset..]) {
            Ok(0) => return Err("connection_failed"),
            Ok(n) => offset += n,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => (),
            Err(_) => return Err("connection_failed"),
        }
    }
    let mut header = [0; 5];
    read_before(stream, &mut header, deadline)?;
    let len = u32::from_be_bytes(header[1..].try_into().unwrap()) as usize;
    if header[0] != 1 || len > CONTROL {
        return Err("incompatible_protocol");
    }
    let mut bytes = vec![0; len];
    read_before(stream, &mut bytes, deadline)?;
    let value: serde_json::Value =
        serde_json::from_slice(&bytes).map_err(|_| "incompatible_protocol")?;
    if value["version"] != 1 {
        return Err("incompatible_protocol");
    }
    if value["type"] == "error" {
        return Err(match value["code"].as_str() {
            Some("busy") => "busy",
            Some("worker_failed") => "worker_failed",
            Some("deadline_exceeded") => "deadline_exceeded",
            _ => "incompatible_protocol",
        });
    }
    let expected = match kind {
        "hello" => "hello_ok",
        "begin" => "accepted",
        "end_audio" => "result",
        "stop" => "stopped",
        _ => kind,
    };
    if value["type"] != expected {
        return Err("incompatible_protocol");
    }
    Ok(value)
}

pub fn cli() -> SafeResult<()> {
    let mut args: Vec<_> = std::env::args().skip(1).collect();
    // Explicit internal controlled-slice harness, never inferred from environment.
    let fake_tests = args.first().is_some_and(|c| c == "__serve")
        && args.last().is_some_and(|c| c == "--fake-test-controls");
    if fake_tests {
        args.pop();
    }
    let command = args.first().map(String::as_str).ok_or(
        "usage: hagig status|stop; hagig start|fake-request --fake-worker [--network-isolation required|disabled]",
    )?;
    let mode = match args.as_slice() {
        [c] if c == "status" || c == "stop" => NetworkIsolation::Required,
        [_, f] if f == "--fake-worker" => NetworkIsolation::Required,
        [_, f, option, value] if f == "--fake-worker" && option == "--network-isolation" => {
            match value.as_str() {
                "required" => NetworkIsolation::Required,
                "disabled" => NetworkIsolation::Disabled,
                _ => return Err("invalid_isolation_mode"),
            }
        }
        _ => return Err("invalid_arguments"),
    };
    if command == "__serve" {
        return serve(mode, fake_tests);
    }
    if !["start", "fake-request", "status", "stop"].contains(&command) {
        return Err("invalid_command");
    }
    let starts = matches!(command, "start" | "fake-request");
    let path = runtime(starts)?;
    let mut stream = connect(&path)?;
    if stream.is_none() && starts {
        let mut child = Command::new(std::env::current_exe().map_err(|_| "startup_failed")?)
            .args([
                "__serve",
                "--fake-worker",
                "--network-isolation",
                &mode.to_string(),
            ])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|_| "startup_failed")?;
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline {
            match connect(&path) {
                Ok(Some(s)) => {
                    stream = Some(s);
                    break;
                }
                Ok(None) => (),
                Err(error) => {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err(error);
                }
            }
            std::thread::sleep(TICK);
        }
        // Reap losing/failed startup children. A winner remains the on-demand server.
        if stream.is_none() {
            let _ = child.kill();
            let _ = child.wait();
            return Err("startup_failed");
        }
        std::thread::spawn(move || {
            let _ = child.wait();
        });
    }
    let Some(mut stream) = stream else {
        println!("stopped");
        return Ok(());
    };
    exchange(&mut stream, "hello")?;
    if command == "fake-request" {
        exchange(&mut stream, "begin")?;
        let result = exchange(&mut stream, "end_audio")?;
        if result["request_id"] != "cli" || result["text"] != "" {
            return Err("incompatible_protocol");
        }
        println!();
        return Ok(());
    }
    let response = exchange(
        &mut stream,
        if command == "stop" { "stop" } else { "status" },
    )?;
    if command == "stop" {
        validate(&path.join("server.lock"), 0o600, "file")?;
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .open(path.join("server.lock"))
            .map_err(|_| "cleanup_failed")?;
        let deadline = Instant::now() + Duration::from_secs(6);
        loop {
            if lock.try_lock().is_ok() {
                if fs::symlink_metadata(path.join("server.sock")).is_ok() {
                    return Err("cleanup_failed");
                }
                break;
            }
            if Instant::now() >= deadline {
                return Err("cleanup_failed");
            }
            std::thread::sleep(TICK);
        }
    }
    println!("{response}");
    Ok(())
}

struct Client {
    stream: UnixStream,
    input: Vec<u8>,
    output: Vec<u8>,
    unsent_result: Option<String>,
    hello: bool,
    closing: bool,
    touched: Instant,
    created: Instant,
    frame_started: Option<Instant>,
}

impl Client {
    fn reply(&mut self, kind: &str, id: Option<&str>, code: Option<&str>) {
        self.output.extend(packet(
            &json!({"version":1,"type":kind,"request_id":id,"code":code}),
        ));
    }
}

struct Active {
    owner: u64,
    id: String,
    generation: u64,
    bytes: usize,
    deadline: Instant,
    cancel: Option<SyncSender<()>>,
    worker_pid: Option<u32>,
    valid: bool,
}

enum WorkerEvent {
    Started(u64, u32),
    Finished(u64, bool),
}

fn invalidate(active: &mut Option<Active>) {
    if let Some(a) = active {
        a.valid = false;
        if let Some(cancel) = &a.cancel {
            let _ = cancel.try_send(());
        } else {
            *active = None;
        }
    }
}

fn run_worker(
    mode: NetworkIsolation,
    action: u8,
    generation: u64,
    done: Sender<WorkerEvent>,
) -> SyncSender<()> {
    let (cancel, cancelled) = mpsc::sync_channel(1);
    std::thread::spawn(move || {
        let success = worker(mode, action, cancelled, generation, &done);
        let _ = done.send(WorkerEvent::Finished(generation, success));
    });
    cancel
}

fn worker(
    mode: NetworkIsolation,
    action: u8,
    cancelled: Receiver<()>,
    generation: u64,
    done: &Sender<WorkerEvent>,
) -> bool {
    let Ok(exe) = std::env::current_exe() else {
        return false;
    };
    let Ok(exe) = WorkerExecutable::new(exe.with_file_name("hagig-fake-worker")) else {
        return false;
    };
    let mut supervisor = Supervisor::new(PlatformLauncher::new(exe).with_network_isolation(mode));
    let Ok(mut pipes) = supervisor.start() else {
        return false;
    };
    if pipes.input.write_all(&[action]).is_err() {
        return false;
    }
    let deadline = Instant::now() + Duration::from_secs(120);
    let mut success = false;
    let _ = done.send(WorkerEvent::Started(
        generation,
        supervisor.child_id().expect("successful start owns child"),
    ));
    while Instant::now() < deadline && cancelled.try_recv().is_err() {
        use rustix::event::{PollFd, PollFlags, Timespec, poll};
        let mut fds = [PollFd::new(&pipes.output, PollFlags::IN)];
        if poll(
            &mut fds,
            Some(&Timespec::try_from(Duration::from_millis(10)).unwrap()),
        )
        .is_ok_and(|n| n > 0)
        {
            let mut byte = [0];
            if pipes.output.read_exact(&mut byte).is_err() {
                break;
            }
            success = byte[0] == 1;
            break;
        }
    }
    // Report completion only after kill/reap; never admit a successor before this.
    while supervisor.stop().is_err() {
        std::thread::sleep(Duration::from_millis(10));
    }
    success
}

fn serve(mode: NetworkIsolation, fake_tests: bool) -> SafeResult<()> {
    let path = runtime(true)?;
    let lockpath = path.join("server.lock");
    if fs::symlink_metadata(&lockpath).is_ok() {
        validate(&lockpath, 0o600, "file")?;
    }
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .open(&lockpath)
        .map_err(|_| "unsafe_runtime")?;
    validate(&lockpath, 0o600, "file")?;
    match lock.try_lock() {
        Ok(()) => (),
        Err(std::fs::TryLockError::WouldBlock) => return Ok(()),
        Err(_) => return Err("lock_failed"),
    }
    let socket = path.join("server.sock");
    match fs::symlink_metadata(&socket) {
        Ok(_) => {
            validate(&socket, 0o600, "socket")?;
            fs::remove_file(&socket).map_err(|_| "cleanup_failed")?;
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => (),
        Err(_) => return Err("unsafe_runtime"),
    }
    // Before any threads exist, bind with owner-read/write only from inception.
    // Avoid a readiness race where a competing startup sees a permissive socket.
    let previous = rustix::process::umask(rustix::fs::Mode::from_raw_mode(0o177));
    let bound = UnixListener::bind(&socket);
    rustix::process::umask(previous);
    let listener = bound.map_err(|_| "bind_failed")?;
    let identity = fs::symlink_metadata(&socket).map_err(|_| "bind_failed")?;
    listener.set_nonblocking(true).map_err(|_| "bind_failed")?;
    let result = event_loop(&listener, mode, fake_tests);
    // Never unlink a replacement object, even though same-user attacks are out of scope.
    validate(&socket, 0o600, "socket")?;
    let current = fs::symlink_metadata(&socket).map_err(|_| "cleanup_failed")?;
    if (current.dev(), current.ino()) != (identity.dev(), identity.ino()) {
        return Err("cleanup_failed");
    }
    fs::remove_file(socket).map_err(|_| "cleanup_failed")?;
    drop(lock);
    result
}

fn event_loop(listener: &UnixListener, mode: NetworkIsolation, fake_tests: bool) -> SafeResult<()> {
    let mut clients = std::collections::BTreeMap::<u64, Client>::new();
    let mut next = 0u64;
    let mut generation = 0u64;
    let mut active: Option<Active> = None;
    let (done, completed) = mpsc::channel();
    let mut tests = FakeTests {
        clock: fake_tests.then(Instant::now),
        ..FakeTests::default()
    };
    // At most one active generation; hold at most its single completion event.
    let mut pending_completion = None;
    let mut stopping = false;
    let mut stop_started = None;
    loop {
        if active
            .as_ref()
            .is_some_and(|a| tests.now() >= a.deadline && a.valid)
        {
            let a = active.as_ref().unwrap();
            if let Some(c) = clients.get_mut(&a.owner) {
                c.reply("error", Some(&a.id), Some("deadline_exceeded"));
                // Reservation expiry and idle expiry coincide at 330s. Do not
                // discard the terminal error before delivery can begin.
                c.touched = tests.now();
            }
            invalidate(&mut active);
        }
        if !stopping {
            // Bound accept work per tick, not only the total live connections.
            for _ in 0..32 {
                match listener.accept() {
                    Ok((stream, _)) if clients.len() < 32 => {
                        stream
                            .set_nonblocking(true)
                            .map_err(|_| "connection_failed")?;
                        next += 1;
                        clients.insert(
                            next,
                            Client {
                                stream,
                                input: Vec::new(),
                                output: Vec::new(),
                                unsent_result: None,
                                hello: false,
                                closing: false,
                                touched: tests.now(),
                                created: Instant::now(),
                                frame_started: None,
                            },
                        );
                    }
                    Ok(_) => (),
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => break,
                    Err(_) => return Err("accept_failed"),
                }
            }
        }
        let mut closed = Vec::new();
        tests.pending_results = clients
            .values()
            .filter(|c| c.unsent_result.is_some())
            .count();
        tests.pending_completions = usize::from(pending_completion.is_some());
        for (&owner, c) in &mut clients {
            let mut buffer = [0; 8192];
            match c.stream.read(&mut buffer) {
                Ok(0) => {
                    closed.push(owner);
                    continue;
                }
                Ok(n) => {
                    if c.input.is_empty() {
                        c.frame_started = Some(Instant::now());
                    }
                    c.input.extend_from_slice(&buffer[..n]);
                    c.touched = tests.now();
                }
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => (),
                Err(_) => {
                    closed.push(owner);
                    continue;
                }
            }
            let mut malformed = false;
            // One frame/client/tick prevents a chatty peer starving other clients.
            if !c.closing && c.input.len() >= 5 {
                let kind = c.input[0];
                let len = u32::from_be_bytes(c.input[1..5].try_into().unwrap()) as usize;
                if !matches!(kind, 1 | 2) || len > if kind == 1 { CONTROL } else { AUDIO } {
                    malformed = true;
                } else if c.input.len() >= len + 5 {
                    let payload: Vec<_> = c.input.drain(..len + 5).skip(5).collect();
                    c.frame_started = if c.input.is_empty() {
                        None
                    } else {
                        Some(Instant::now())
                    };
                    if kind == 2 {
                        match &mut active {
                            Some(a)
                                if a.owner == owner
                                    && a.valid
                                    && a.cancel.is_none()
                                    && len > 0
                                    && len.is_multiple_of(4)
                                    && a.bytes + len <= TOTAL_AUDIO =>
                            {
                                a.bytes += len
                            }
                            _ => malformed = true,
                        }
                    } else {
                        match serde_json::from_slice::<Control>(&payload) {
                            Ok(control) => {
                                malformed = !handle(
                                    control,
                                    owner,
                                    c,
                                    &mut active,
                                    &mut generation,
                                    mode,
                                    &done,
                                    &mut stopping,
                                    &mut tests,
                                )
                            }
                            Err(_) => malformed = true,
                        }
                    }
                }
            }
            // Hard cap even when a peer pipelines faster than frames are consumed.
            if malformed
                || (!c.hello && c.created.elapsed() > Duration::from_secs(5))
                || c.frame_started
                    .is_some_and(|t| t.elapsed() > Duration::from_secs(5))
                || c.input.len() > AUDIO + 5
                || c.output.len() > CONTROL * 2
                || (tests.now().duration_since(c.touched) > Duration::from_secs(330)
                    && active.as_ref().is_none_or(|a| a.owner != owner))
            {
                closed.push(owner);
                continue;
            }
        }
        for id in closed {
            clients.remove(&id);
            if active.as_ref().is_some_and(|a| a.owner == id) {
                invalidate(&mut active);
            }
        }
        // Process completions after all observed controls/disconnects. Invalidation
        // wins before delivery initiation; completion cannot release a successor early.
        let event = pending_completion
            .take()
            .or_else(|| completed.try_recv().ok());
        if let Some(event) = event {
            if matches!(event, WorkerEvent::Finished(..)) && tests.pause_completion && !stopping {
                pending_completion = Some(event);
            } else {
                match event {
                    WorkerEvent::Started(g, pid) => {
                        if let Some(a) = active.as_mut().filter(|a| a.generation == g) {
                            a.worker_pid = Some(pid);
                        }
                    }
                    WorkerEvent::Finished(g, success)
                        if active.as_ref().is_some_and(|a| a.generation == g) =>
                    {
                        let a = active.take().unwrap();
                        if a.valid
                            && let Some(c) = clients.get_mut(&a.owner)
                        {
                            if success {
                                // Do not place content behind unconsumed earlier replies.
                                // A slow owner fails safely rather than retaining a result.
                                if c.output.is_empty() {
                                    c.output.extend(packet(&json!({"version":1,"type":"result","request_id":a.id,"text":""})));
                                    c.unsent_result = Some(a.id);
                                } else {
                                    c.closing = true;
                                }
                            } else {
                                c.reply("error", Some(&a.id), Some("worker_failed"));
                            }
                        }
                    }
                    _ => (),
                }
            }
        }
        clients.retain(|_, c| {
            if stopping && c.unsent_result.take().is_some() {
                c.output.clear();
            }
            if !(c.output.is_empty() || tests.pause_delivery && c.unsent_result.is_some()) {
                match c.stream.write(&c.output) {
                    Ok(0) => return false,
                    Ok(n) => {
                        // First successful write is delivery initiation. Later
                        // cancellation cannot undo bytes already sent to a client.
                        c.unsent_result = None;
                        c.output.drain(..n);
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => (),
                    Err(_) => return false,
                }
            }
            !(c.closing && c.output.is_empty())
        });
        if active
            .as_ref()
            .is_some_and(|a| !clients.contains_key(&a.owner))
        {
            invalidate(&mut active);
        }
        if stopping && stop_started.is_none() {
            stop_started = Some(Instant::now());
        }
        if stop_started.is_some_and(|t| t.elapsed() > Duration::from_secs(1)) {
            // An unresponsive nonowner must not hold shutdown hostage.
            clients.clear();
        }
        if stopping && active.is_none() && clients.values().all(|c| c.output.is_empty()) {
            return Ok(());
        }
        std::thread::sleep(TICK);
    }
}

#[allow(clippy::too_many_arguments)]
fn handle(
    control: Control,
    owner: u64,
    c: &mut Client,
    active: &mut Option<Active>,
    generation: &mut u64,
    mode: NetworkIsolation,
    done: &Sender<WorkerEvent>,
    stopping: &mut bool,
    tests: &mut FakeTests,
) -> bool {
    let id = control.request_id.as_deref();
    if control.version != 1 {
        c.reply("error", None, Some("incompatible_protocol"));
        c.closing = true;
        if active.as_ref().is_some_and(|a| a.owner == owner) {
            invalidate(active);
        }
        return true;
    }
    if id.is_some_and(|id| {
        id.is_empty()
            || id.len() > 128
            || !id
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
    }) {
        return false;
    }
    let test_fields = control.fake_pause_delivery.is_some()
        || control.fake_pause_completion.is_some()
        || control.fake_advance_seconds.is_some();
    if test_fields && control.kind != "fake_test" {
        return false;
    }
    if !c.hello {
        if control.kind != "hello" || id.is_some() || control.fake_action.is_some() {
            return false;
        }
        c.hello = true;
        c.output.extend(packet(&json!({"version":1,"type":"hello_ok","worker":"controlled_fake","network_isolation":mode.to_string(),"control_limit":CONTROL,"audio_limit":AUDIO})));
        return true;
    }
    if control.fake_action.is_some() && control.kind != "end_audio" {
        return false;
    }
    match control.kind.as_str() {
        "fake_test" if tests.clock.is_some() && id.is_none() && test_fields => {
            let advance = Duration::from_secs(control.fake_advance_seconds.unwrap_or(0).into());
            if advance > Duration::from_secs(3600)
                || tests.advance + advance > Duration::from_secs(86_400)
            {
                return false;
            }
            tests.advance += advance;
            c.touched = tests.now();
            if let Some(pause) = control.fake_pause_delivery {
                tests.pause_delivery = pause;
            }
            if let Some(pause) = control.fake_pause_completion {
                tests.pause_completion = pause;
            }
            c.reply("fake_test_ok", None, None);
        }
        "status" if id.is_none() => {
            let mut response = json!({"version":1,"type":"status","state":if active.is_some() {"busy"} else {"idle"},"worker":"controlled_fake","network_isolation":mode.to_string(),"server_pid":std::process::id(),"worker_pid":active.as_ref().and_then(|a| a.worker_pid)});
            if tests.clock.is_some() {
                response["pending_results"] = json!(tests.pending_results);
                response["pending_completions"] = json!(tests.pending_completions);
            }
            c.output.extend(packet(&response));
        }
        "stop" if id.is_none() => {
            *stopping = true;
            invalidate(active);
            c.reply("stopped", None, None);
        }
        "begin" if id.is_some() && control.fake_action.is_none() => {
            if active.is_some() || *stopping {
                c.reply("error", id, Some("busy"));
            } else {
                *generation += 1;
                *active = Some(Active {
                    owner,
                    id: id.unwrap().to_owned(),
                    generation: *generation,
                    bytes: 0,
                    deadline: tests.now() + Duration::from_secs(330),
                    cancel: None,
                    worker_pid: None,
                    valid: true,
                });
                c.reply("accepted", id, None);
            }
        }
        "cancel" if id.is_some() && control.fake_action.is_none() => {
            if c.unsent_result.as_deref() == id {
                c.output.clear();
                c.unsent_result = None;
            }
            if active
                .as_ref()
                .is_some_and(|a| a.owner == owner && Some(a.id.as_str()) == id)
            {
                invalidate(active);
            }
            c.reply("cancelled", id, None);
        }
        "end_audio" if id.is_some() => {
            let Some(a) = active.as_mut().filter(|a| {
                a.owner == owner && Some(a.id.as_str()) == id && a.valid && a.cancel.is_none()
            }) else {
                return false;
            };
            let action = match control.fake_action.as_deref() {
                None | Some("complete") => 0,
                Some("crash") => 1,
                Some("stall") => 2,
                _ => return false,
            };
            a.cancel = Some(run_worker(mode, action, a.generation, done.clone()));
            a.deadline = tests.now() + Duration::from_secs(120);
        }
        _ => return false,
    }
    true
}
