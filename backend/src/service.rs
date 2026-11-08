//! Serial service lifecycle, public protocol and controlled fake exerciser.

use crate::launcher::{NetworkIsolation, PlatformLauncher, WorkerExecutable};
use crate::supervisor::{Supervisor, WorkerPipes};
use serde::Deserialize;
use serde_json::json;
use std::fs::{self, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::mpsc::{self, Sender, SyncSender};
use std::time::{Duration, Instant};

mod client;
mod fake;
mod inference;
mod paths;
pub use client::cli;
use paths::{runtime, validate};

const CONTROL: usize = 65_536;
const AUDIO: usize = 262_144;
const TOTAL_AUDIO: usize = 19_200_000;
const TICK: Duration = Duration::from_millis(5);
type SafeResult<T> = Result<T, &'static str>;

/// Real connections must reject fake-only fields even if their value is null.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct InferenceControl {
    version: u32,
    #[serde(rename = "type")]
    kind: String,
    request_id: Option<String>,
}

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
    audio: Vec<u8>,
    deadline: Instant,
    cancel: Option<SyncSender<()>>,
    worker_pid: Option<u32>,
    worker_reply_bytes: usize,
    valid: bool,
}

enum WorkerEvent {
    Started(u64, u32),
    Progress(u64, usize),
    Finished(u64, SafeResult<String>, Option<LiveWorker>),
}

struct LiveWorker {
    supervisor: Supervisor<PlatformLauncher>,
    pipes: WorkerPipes,
}

#[derive(Clone)]
struct InferenceSettings {
    config: crate::config::Config,
    model: std::path::PathBuf,
    generation: String,
}
impl InferenceSettings {
    fn load() -> SafeResult<Self> {
        Ok(Self {
            config: crate::config::Config::load()?,
            model: crate::model::installation()?,
            generation: format!(
                "server-{}-{}",
                std::process::id(),
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map_err(|_| "startup_failed")?
                    .as_nanos()
            ),
        })
    }
}

enum Job {
    Fake(u8),
    Inference(InferenceSettings, Vec<u8>),
}

fn start_worker(mode: NetworkIsolation, name: &str) -> SafeResult<LiveWorker> {
    let exe = std::env::current_exe().map_err(|_| "worker_failed")?;
    let exe = WorkerExecutable::new(exe.with_file_name(name)).map_err(|_| "worker_failed")?;
    let mut supervisor = Supervisor::new(PlatformLauncher::new(exe).with_network_isolation(mode));
    let pipes = supervisor.start().map_err(|_| "worker_failed")?;
    Ok(LiveWorker { supervisor, pipes })
}
// Ownership transfers through completion events, never shared between threads.
// A failed reap deliberately blocks replacement rather than losing child ownership.
fn retire(warm: &mut Option<LiveWorker>) -> bool {
    if let Some(worker) = warm.as_mut()
        && worker.supervisor.stop().is_err()
    {
        return false;
    }
    *warm = None;
    true
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
    job: Job,
    generation: u64,
    id: String,
    mut warm: Option<LiveWorker>,
    done: Sender<WorkerEvent>,
) -> SyncSender<()> {
    let (cancel, cancelled) = mpsc::sync_channel(1);
    std::thread::spawn(move || {
        let result = match job {
            Job::Fake(action) => {
                if fake::run(mode, action, cancelled, generation, &id, &mut warm, &done) {
                    Ok(String::new())
                } else {
                    Err("worker_failed")
                }
            }
            Job::Inference(settings, pcm) => {
                inference::run(settings, pcm, cancelled, generation, &id, &mut warm, &done)
            }
        };
        if result.is_err() {
            while !retire(&mut warm) {
                std::thread::sleep(TICK);
            }
        }
        let _ = done.send(WorkerEvent::Finished(generation, result, warm));
    });
    cancel
}

fn serve(
    mode: NetworkIsolation,
    fake_tests: bool,
    settings: Option<InferenceSettings>,
) -> SafeResult<()> {
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
    let result = event_loop(&listener, mode, fake_tests, settings);
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

fn event_loop(
    listener: &UnixListener,
    mode: NetworkIsolation,
    fake_tests: bool,
    settings: Option<InferenceSettings>,
) -> SafeResult<()> {
    let mut clients = std::collections::BTreeMap::<u64, Client>::new();
    let mut next = 0u64;
    let mut generation = 0u64;
    let mut active: Option<Active> = None;
    let mut warm = None;
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
                                    && a.bytes + len <= TOTAL_AUDIO
                                    && (settings.is_none()
                                        || payload.chunks_exact(4).all(|s| {
                                            (-1.0..=1.0).contains(&f32::from_le_bytes(
                                                s.try_into().unwrap(),
                                            ))
                                        })) =>
                            {
                                a.bytes += len;
                                if settings.is_some() {
                                    a.audio.extend_from_slice(&payload);
                                }
                            }
                            _ => malformed = true,
                        }
                    } else {
                        let control = if settings.is_some() {
                            serde_json::from_slice::<InferenceControl>(&payload).map(|c| Control {
                                version: c.version,
                                kind: c.kind,
                                request_id: c.request_id,
                                fake_action: None,
                                fake_pause_delivery: None,
                                fake_pause_completion: None,
                                fake_advance_seconds: None,
                            })
                        } else {
                            serde_json::from_slice::<Control>(&payload)
                        };
                        match control {
                            Ok(control) => {
                                malformed = !handle(
                                    control,
                                    owner,
                                    c,
                                    &mut active,
                                    &mut generation,
                                    mode,
                                    &done,
                                    &mut warm,
                                    &mut stopping,
                                    &mut tests,
                                    settings.as_ref(),
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
                    WorkerEvent::Progress(g, bytes) => {
                        if let Some(a) = active.as_mut().filter(|a| a.generation == g) {
                            a.worker_reply_bytes = bytes;
                        }
                    }
                    WorkerEvent::Finished(g, result, mut returned)
                        if active.as_ref().is_some_and(|a| a.generation == g) =>
                    {
                        if !active.as_ref().unwrap().valid && !retire(&mut returned) {
                            // Preserve ownership/admission while retrying cleanup next
                            // tick; a failed stop must not spin on the service loop.
                            pending_completion = Some(WorkerEvent::Finished(g, result, returned));
                        } else {
                            warm = returned;
                            let a = active.take().unwrap();
                            if a.valid
                                && let Some(c) = clients.get_mut(&a.owner)
                            {
                                if let Ok(text) = result {
                                    // Do not place content behind unconsumed earlier replies.
                                    // A slow owner fails safely rather than retaining a result.
                                    if c.output.is_empty() {
                                        let text = if text.trim().is_empty() { "" } else { &text };
                                        let frame = packet(
                                            &json!({"version":1,"type":"result","request_id":a.id,"text":text}),
                                        );
                                        if frame.len() > CONTROL + 5 {
                                            c.reply("error", Some(&a.id), Some("result_too_large"));
                                        } else {
                                            c.output.extend(frame);
                                            c.unsent_result = Some(a.id);
                                        }
                                    } else {
                                        c.closing = true;
                                    }
                                } else {
                                    c.reply("error", Some(&a.id), Some(result.unwrap_err()));
                                }
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
        if stopping
            && active.is_none()
            && clients.values().all(|c| c.output.is_empty())
            && retire(&mut warm)
        {
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
    warm: &mut Option<LiveWorker>,
    stopping: &mut bool,
    tests: &mut FakeTests,
    settings: Option<&InferenceSettings>,
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
    if settings.is_some() && (test_fields || control.fake_action.is_some()) {
        return false;
    }
    if test_fields && control.kind != "fake_test" {
        return false;
    }
    if !c.hello {
        if control.kind != "hello" || id.is_some() || control.fake_action.is_some() {
            return false;
        }
        c.hello = true;
        if let Some(s) = settings {
            c.output.extend(packet(&json!({"version":1,"type":"hello_ok","worker":"inference","network_isolation":mode.to_string(),"config_generation":s.generation,
                "settings":{"editor_mode":s.config.editor_mode(),"model_id":s.config.model_id(),"model_revision":crate::model::manifest().revision,"language":"en"},
                "audio":{"encoding":"f32le","sample_rate_hz":16000,"channels":1},
                "limits":{"control_bytes":CONTROL,"audio_chunk_bytes":AUDIO,"audio_total_bytes":TOTAL_AUDIO,"recording_seconds":300,"warning_seconds":285,"request_id_bytes":128},
                "deadlines":{"control_seconds":5,"reservation_seconds":330,"computation_seconds":120}})));
        } else {
            c.output.extend(packet(&json!({"version":1,"type":"hello_ok","worker":"controlled_fake","network_isolation":mode.to_string(),"control_limit":CONTROL,"audio_limit":AUDIO})));
        }
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
            let pid = warm
                .as_ref()
                .and_then(|w| w.supervisor.child_id())
                .or_else(|| active.as_ref().and_then(|a| a.worker_pid));
            let mut response = json!({"version":1,"type":"status","state":if active.is_some() {"busy"} else {"idle"},"worker":"controlled_fake","network_isolation":mode.to_string(),"server_pid":std::process::id(),"worker_pid":pid});
            if let Some(s) = settings {
                response["worker"] = json!("inference");
                response["model_id"] = json!(s.config.model_id());
                response["config_generation"] = json!(s.generation);
            }
            if tests.clock.is_some() {
                response["pending_results"] = json!(tests.pending_results);
                response["pending_completions"] = json!(tests.pending_completions);
                response["worker_reply_bytes"] =
                    json!(active.as_ref().map_or(0, |a| a.worker_reply_bytes));
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
                    audio: Vec::new(),
                    deadline: tests.now() + Duration::from_secs(330),
                    cancel: None,
                    worker_pid: None,
                    worker_reply_bytes: 0,
                    valid: true,
                });
                if let Some(s) = settings {
                    c.output.extend(packet(&json!({"version":1,"type":"accepted","request_id":id,"config_generation":s.generation,"model_id":s.config.model_id()})));
                } else {
                    c.reply("accepted", id, None);
                }
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
            if settings.is_some() && a.audio.is_empty() {
                c.reply("error", id, Some("invalid_audio"));
                *active = None;
                return true;
            }
            let job = if let Some(s) = settings {
                Job::Inference(s.clone(), std::mem::take(&mut a.audio))
            } else {
                let Some(action) = fake::action(control.fake_action.as_deref()) else {
                    return false;
                };
                Job::Fake(action)
            };
            a.cancel = Some(run_worker(
                mode,
                job,
                a.generation,
                a.id.clone(),
                warm.take(),
                done.clone(),
            ));
            a.deadline = tests.now() + Duration::from_secs(120);
        }
        _ => return false,
    }
    true
}
