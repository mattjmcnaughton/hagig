"""Finite #6 (D6) macOS runtime observation of worker network/write attempts.

Evidence level 2 only (constitution section 6): not source inspection, not a
blocked-network test, not a privacy certificate or inference adoption. See
spikes/inference-s1/MACOS-OBSERVATION.md for the preregistered plan.

Built-in tools only: fs_usage (primary), unified log, lsof and nettop, run
through `sudo -n` for read-only tracing. Raw traces stay under --trace and are
deleted; only bounded content-free summaries are written to the evidence dir.
--smoke checks tracer capture with ordinary controls before any asset download.
"""

import argparse
import hashlib
import json
import os
from collections import Counter
from pathlib import Path
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

BACKEND = Path(__file__).resolve().parent.parent
SPEECH = BACKEND / "tests/fixtures/speech.wav"
WORKER = re.compile(r"^(sandbox-exec|hagig-worker|hagig-inference)")
NETWORK = {"socket", "connect", "bind", "listen", "accept", "sendto", "sendmsg",
           "recvfrom", "recvmsg", "socketpair"}
WRITES = {"write", "writev", "pwrite", "pwritev", "pwrite_extended"}
MUTATIONS = {"rename", "renameat", "renameatx_np", "unlink", "unlinkat", "rmdir",
             "mkdir", "mkdirat", "mkdir_extended", "link", "linkat", "symlink",
             "symlinkat", "truncate", "ftruncate", "chmod", "fchmod", "fchmodat",
             "chmod_extended", "fchmod_extended", "chown", "fchown", "lchown",
             "fchownat", "utimes", "futimes", "lutimes", "futimens", "utimensat",
             "setattrlist", "fsetattrlist", "setattrlistat", "setxattr",
             "fsetxattr", "removexattr", "fremovexattr", "clonefileat",
             "fclonefileat", "exchangedata", "copyfile", "mkfifo", "mknod",
             "mkfifoat", "mknodat", "revoke", "undelete", "msync", "delete"}
EXECS = {"execve", "posix_spawn"}
LINE = re.compile(r"^(\d\d:\d\d:\d\d\.\d{6})\s+(\S+)(.*)\s(\d+\.\d{6})(?: W)?\s+(.+)\.(\d+)$")
TOKENS = re.compile(r"F=\d+|B=0x[0-9a-fA-F]+|O=0x[0-9a-fA-F]+|A=0x[0-9a-fA-F]+|"
                    r"\[\s*-?\d+\]|\([_A-Za-z]{8,20}\)|<[^>]*>")
LSOF_NETWORK = {"IPv4", "IPv6", "unix", "systm", "NPOLICY", "NEXUS", "ndrv", "key", "raw"}
CONTROLS = ("hg6-lead", "hg6-trail")


def digest(path):
    with Path(path).open("rb") as source:
        checksum = hashlib.sha256()
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            checksum.update(chunk)
        return checksum.hexdigest()


def group_of(command):
    if WORKER.match(command):
        return "worker"
    if command == "hagig":
        return "service"
    if command in CONTROLS:
        return command
    return None


class Sanitizer:
    def __init__(self, *pairs):
        self.pairs = sorted(((str(a), b) for a, b in pairs if a), key=lambda p: -len(p[0]))

    def __call__(self, text):
        for prefix, label in self.pairs:
            text = text.replace(prefix, label)
        return re.sub(r"/(private/)?var/folders/[^/\s]+/[^/\s]+/", "$VAR_FOLDERS/", text)


def base_call(call):
    return call.removesuffix("_nocancel")


def new_group():
    return {"events": 0, "network": Counter(), "writable_opens": [], "writable_open_count": 0,
            "open_paths": Counter(), "mutations": Counter(), "mutation_paths": [],
            "writes_by_fd": Counter(), "write_paths": Counter(), "execs": Counter(),
            "write_fds_opened_writable": Counter(), "excerpt": []}


def parse_fs_usage(raw, sanitize, excerpt_limit=300):
    """Summarize fs_usage -w lines per process group; never keep raw read lines."""
    groups = {}
    unparsed = 0
    total = 0
    with raw.open(errors="replace") as source:
        for line in source:
            line = line.rstrip("\n")
            if not line.strip():
                continue
            total += 1
            match = LINE.match(line)
            if not match:
                unparsed += 1
                continue
            _, call, middle, _, command, thread = match.groups()
            group_name = group_of(command)
            if group_name is None:
                continue
            group = groups.setdefault(group_name, new_group())
            group.setdefault("writable_fds", {})
            group["events"] += 1
            base = base_call(call)
            fd = re.search(r"F=(\d+)", middle)
            fd = int(fd.group(1)) if fd else None
            errno = re.search(r"\[\s*(-?\d+)\]", middle)
            errno = int(errno.group(1)) if errno else 0
            mode = re.search(r"\(([_A-Za-z]{8,20})\)", middle)
            path = sanitize(TOKENS.sub("", middle).strip())
            interesting = None
            if base in NETWORK:
                group["network"][f"{base} errno={errno}"] += 1
                interesting = "network"
            elif "open" in base and mode:
                flags = mode.group(1)
                if path:
                    group["open_paths"][Path(path).name] += 1
                if "W" in flags[:2] or any(flag in flags[2:5] for flag in "CAT"):
                    group["writable_open_count"] += 1
                    if len(group["writable_opens"]) < 50:
                        group["writable_opens"].append(
                            {"call": call, "mode": flags, "errno": errno, "fd": fd, "path": path})
                    if errno == 0 and fd is not None:
                        group["writable_fds"][fd] = path
                    interesting = "writable-open"
            elif base in WRITES:
                group["writes_by_fd"][str(fd)] += 1
                if path:
                    group["write_paths"][path] += 1
                if fd in group["writable_fds"]:
                    group["write_fds_opened_writable"][group["writable_fds"][fd]] += 1
                interesting = "write"
            elif base in MUTATIONS or base.startswith(("rename", "unlink", "clonefile")):
                group["mutations"][f"{base} errno={errno}"] += 1
                if len(group["mutation_paths"]) < 50:
                    group["mutation_paths"].append({"call": call, "errno": errno, "path": path})
                interesting = "mutation"
            elif base in EXECS:
                group["execs"][f"{base} errno={errno} {Path(path).name if path else ''}".strip()] += 1
                interesting = "exec"
            elif base in {"close", "guarded_close_np"} and fd in group["writable_fds"]:
                del group["writable_fds"][fd]
            if interesting and len(group["excerpt"]) < excerpt_limit:
                # Synthetic paths, syscall names, descriptors and errno only.
                group["excerpt"].append(f"{command} {interesting} {call} fd={fd} errno={errno} {path}".rstrip())
    for group in groups.values():
        group.pop("writable_fds", None)
        group["open_paths"] = dict(group["open_paths"].most_common(40))
        group["write_paths"] = dict(group["write_paths"].most_common(40))
        for key in ("network", "mutations", "writes_by_fd", "execs", "write_fds_opened_writable"):
            group[key] = dict(group[key])
    return {"lines": total, "unparsed_lines": unparsed, "groups": groups}


def parse_lsof(text, sanitize, state):
    command = None
    record = {}
    entries = []
    for line in text.splitlines():
        if not line:
            continue
        tag, value = line[0], line[1:]
        if tag == "p":
            command = None
        elif tag == "c":
            command = value
        elif tag == "f":
            if record:
                entries.append(record)
            record = {"command": command, "fd": value}
        elif tag in "atn" and record:
            record[tag] = value
    if record:
        entries.append(record)
    present = set()
    for entry in entries:
        group_name = group_of(entry.get("command") or "")
        if group_name is None:
            continue
        group = state.setdefault(group_name, {"samples": 0, "types": Counter(), "network_fds": Counter(),
                                              "writable_regular": Counter()})
        if group_name not in present:
            present.add(group_name)
            group["samples"] += 1
        kind = entry.get("t", "")
        group["types"][kind] += 1
        if kind in LSOF_NETWORK:
            group["network_fds"][f"{kind} {sanitize(entry.get('n', ''))}"[:160]] += 1
        if kind == "REG" and entry["fd"].isdigit() and entry.get("a") in ("w", "u"):
            group["writable_regular"][sanitize(entry.get("n", ""))] += 1


class Samplers:
    """lsof descriptor snapshots every 0.5 s; nettop single samples back to back."""

    def __init__(self, sanitize, port):
        self.sanitize = sanitize
        self.port = port
        self.stop = threading.Event()
        self.lsof = {}
        self.lsof_errors = Counter()
        self.nettop = {"samples": 0, "errors": 0, "subject_lines": 0, "listener_lines": 0,
                       "subject_samples": 0, "listener_samples": 0, "excerpt": []}
        self.threads = [threading.Thread(target=self.run_lsof), threading.Thread(target=self.run_nettop)]

    def start(self):
        for thread in self.threads:
            thread.start()

    def finish(self):
        self.stop.set()
        for thread in self.threads:
            thread.join(timeout=30)
        result = {"lsof": {}, "lsof_errors": dict(self.lsof_errors), "nettop": self.nettop}
        for name, group in self.lsof.items():
            result["lsof"][name] = {key: dict(value) if isinstance(value, Counter) else value
                                    for key, value in group.items()}
        return result

    def run_lsof(self):
        pattern = r"(Contents/Helpers/hagig-(inference-)?worker|/hg6-(lead|trail)$)"
        while not self.stop.is_set():
            started = time.monotonic()
            pids = subprocess.run(["/usr/bin/pgrep", "-f", pattern], capture_output=True, text=True)
            pids = ",".join(pids.stdout.split())
            if pids:
                listed = subprocess.run(["sudo", "-n", "/usr/sbin/lsof", "+c", "0", "-n", "-P", "-w", "-F", "pcftan",
                                         "-p", pids], capture_output=True, text=True, timeout=20)
                if listed.returncode not in (0, 1):
                    self.lsof_errors[str(listed.returncode)] += 1
                parse_lsof(listed.stdout, self.sanitize, self.lsof)
            self.stop.wait(max(0.0, 0.5 - (time.monotonic() - started)))

    def run_nettop(self):
        subject = re.compile(r"hagig|hg6-|sandbox-exec")
        listener = re.compile(rf"127\.0\.0\.1[.:]{self.port}\b")
        while not self.stop.is_set():
            started = time.monotonic()
            try:
                sample = subprocess.run(["sudo", "-n", "/usr/bin/nettop", "-L", "1", "-n", "-x"],
                                        capture_output=True, text=True, timeout=15)
            except subprocess.TimeoutExpired:
                self.nettop["errors"] += 1
                continue
            if sample.returncode != 0:
                self.nettop["errors"] += 1
            self.nettop["samples"] += 1
            seen_subject = seen_listener = False
            for line in sample.stdout.splitlines():
                is_subject, is_listener = bool(subject.search(line)), bool(listener.search(line))
                seen_subject |= is_subject
                seen_listener |= is_listener
                self.nettop["subject_lines"] += is_subject
                self.nettop["listener_lines"] += is_listener
                if (is_subject or is_listener) and len(self.nettop["excerpt"]) < 60:
                    self.nettop["excerpt"].append(self.sanitize(line)[:240])
            self.nettop["subject_samples"] += seen_subject
            self.nettop["listener_samples"] += seen_listener
            self.stop.wait(max(0.0, 1.0 - (time.monotonic() - started)))


class Listener:
    """Loopback TCP/UDP ground truth for the controls; counts only, no payload kept."""

    def __init__(self):
        self.tcp = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.tcp.bind(("127.0.0.1", 0))
        self.port = self.tcp.getsockname()[1]
        self.tcp.listen(16)
        self.udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.udp.bind(("127.0.0.1", self.port))
        self.accepted = 0
        self.datagrams = 0
        for target in (self.accept, self.receive):
            threading.Thread(target=target, daemon=True).start()

    def accept(self):
        while True:
            connection, _ = self.tcp.accept()
            self.accepted += 1
            connection.close()

    def receive(self):
        while True:
            self.udp.recvfrom(64)
            self.datagrams += 1

    def counts(self):
        time.sleep(0.3)
        return self.accepted, self.datagrams


def log_show(start, end, predicate, extra=()):
    try:
        shown = subprocess.run(["sudo", "-n", "/usr/bin/log", "show", "--style", "ndjson", *extra,
                                "--start", start, "--end", end, "--predicate", predicate],
                               capture_output=True, text=True, timeout=90)
    except subprocess.TimeoutExpired:
        return "timeout", []
    events = []
    for line in shown.stdout.splitlines():
        if line.startswith("{"):
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if "eventMessage" in event or "processImagePath" in event:
                events.append(event)
    return shown.returncode, events


def unified_log(start, end, sanitize):
    status, events = log_show(start, end,
                              'sender == "Sandbox" OR subsystem == "com.apple.sandbox.reporting"')
    denials = {}
    excerpt = []
    for event in events:
        message = event.get("eventMessage", "")
        named = re.search(r"(?:Sandbox: )?([A-Za-z0-9_.-]+)\(\d+\) (deny|allow)\(\d+\) (\S+)", message)
        if not named:
            continue
        group_name = group_of(named.group(1))
        if group_name is None:
            continue
        key = f"{named.group(2)} {named.group(3)}"
        denials.setdefault(group_name, Counter())[key] += 1
        if len(excerpt) < 20:
            excerpt.append(sanitize(message)[:240])
    process_status, process_events = log_show(
        start, end, 'process BEGINSWITH "hagig" OR process BEGINSWITH "hg6-" OR process == "sandbox-exec"',
        ("--info", "--debug"))
    emitted = Counter()
    for event in process_events:
        name = Path(event.get("processImagePath", "")).name
        emitted[" ".join(str(part) for part in (
            group_of(name) or name, event.get("messageType", ""), event.get("subsystem", "") or "-",
            event.get("category", "") or "-"))] += 1
    return {"sandbox_status": status, "sandbox_reports": {k: dict(v) for k, v in denials.items()},
            "sandbox_excerpt": excerpt, "process_log_status": process_status,
            "process_log_entries": dict(emitted)}


class Observation:
    def __init__(self, args):
        self.args = args
        self.trace = args.trace
        self.evidence = args.evidence
        self.root = args.root
        self.listener = Listener()
        self.bin = self.trace / "bin"
        self.writes = self.trace / "writes"
        self.bin.mkdir()
        self.writes.mkdir()
        self.sanitize = Sanitizer((self.root, "$NATIVE_ROOT"), (self.trace, "$TRACE"),
                                  (os.environ.get("RUNNER_TEMP"), "$RUNNER_TEMP"),
                                  (str(Path.home()), "~"))
        probe = self.bin / "probe"
        env = dict(os.environ, HG6_PORT=str(self.listener.port), HG6_WRITE_DIR=str(self.writes))
        subprocess.run(["rustc", "--edition", "2024", "-O", "-o", str(probe),
                        str(BACKEND / "tests/fixtures/observation_probe.rs")],
                       cwd=BACKEND, env=env, check=True, timeout=300)
        self.probe = probe
        for name in CONTROLS:
            shutil.copy2(probe, self.bin / name)
        self.servers_stopped = True
        self.sessions = []

    def ordinary(self, name):
        before = self.listener.counts()
        result = subprocess.run([str(self.bin / name)], env={}, cwd="/", capture_output=True, timeout=30)
        after = self.listener.counts()
        return self.control_record(name, result.returncode, before, after)

    def control_record(self, name, status, before, after):
        written = self.writes / f"{name}.written"
        content = written.read_text().strip() if written.exists() else None
        if written.exists():
            written.unlink()
        return {"status": status, "file": content, "tcp_accepted": after[0] - before[0],
                "udp_datagrams": after[1] - before[1]}

    def launch_control(self, mode):
        helper = self.root / "Contents/Helpers/hagig-inference-worker"
        original = helper.with_name("hagig-inference-worker.observation-original")
        expected = digest(helper)
        os.rename(helper, original)
        shutil.copy2(self.probe, helper)
        record = {"mode": mode}
        try:
            before = self.listener.counts()
            with tempfile.TemporaryDirectory(prefix="hg6-", dir="/tmp") as runtime:
                record.update(self.serve_once(Path(runtime), mode))
            after = self.listener.counts()
            record["control"] = self.control_record("hagig-inference-worker", record.get("transcribe_status"),
                                                    before, after)
        finally:
            os.replace(original, helper)
            record["helper_restored"] = digest(helper) == expected
        return record

    def serve_once(self, runtime, mode):
        exe = self.root / "Contents/Helpers/hagig"
        runtime.chmod(0o700)
        env = {k: v for k, v in os.environ.items() if not k.startswith(("DYLD_", "LD_"))}
        env.update(XDG_DATA_HOME=str(self.root / "data"), XDG_RUNTIME_DIR=str(runtime),
                   XDG_CONFIG_HOME=str(runtime / "config"))
        (runtime / "config/hagig").mkdir(parents=True)
        (runtime / "config/hagig/config.toml").write_text(f"[inference]\nnetwork_isolation='{mode}'\n")
        record = {}
        self.servers_stopped = False
        server = subprocess.Popen([str(exe), "__serve"], env=env, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 8
            while not (runtime / "hagig/server.sock").exists():
                if server.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError("server did not start")
                time.sleep(0.01)
            status = subprocess.run([str(exe), "status"], env=env, capture_output=True, timeout=30)
            record["status_mode"] = json.loads(status.stdout).get("network_isolation")
            result = subprocess.run([str(exe), "transcribe", str(SPEECH)], env=env,
                                    capture_output=True, timeout=150)
            record["transcribe_status"] = result.returncode
            record["transcribe_stdout_bytes"] = len(result.stdout)
            record["transcribe_stderr"] = result.stderr.decode(errors="replace")[:80]
        finally:
            stopped = subprocess.run([str(exe), "stop"], env=env, capture_output=True, timeout=30)
            try:
                out, err = server.communicate(timeout=10)
                record["server_exit"] = server.returncode
                record["stop_status"] = stopped.returncode
                self.servers_stopped = stopped.returncode == 0 and server.returncode == 0
            except subprocess.TimeoutExpired:
                record["server_exit"] = None
        return record

    def real(self, mode):
        command = [sys.executable, "tests/native_speech.py", "--root", str(self.root)]
        if mode == "disabled":
            command += ["--mode", "disabled"]
        self.servers_stopped = False
        result = subprocess.run(command, cwd=BACKEND, capture_output=True, text=True, timeout=600)
        output = result.stdout + result.stderr
        (self.evidence / f"speech-{mode}.txt").write_text(self.sanitize(output))
        passed = f"STOP/REAP AND INPUT PRESERVATION PASS {mode}" in output
        self.servers_stopped = passed
        return {"mode": mode, "status": result.returncode, "stop_reap_pass": passed,
                "lifecycle_pass": "LIFECYCLE PASS" in output}

    def stop_tracer(self, process, name):
        subprocess.run(["sudo", "-n", "/usr/bin/pkill", "-INT", "-x", name], capture_output=True)
        try:
            return process.wait(timeout=60)
        except subprocess.TimeoutExpired:
            subprocess.run(["sudo", "-n", "/usr/bin/pkill", "-KILL", "-x", name], capture_output=True)
            process.wait(timeout=10)
            return "killed"

    def session(self, name, workload):
        directory = self.trace / name
        directory.mkdir()
        raw, errors = directory / "fs_usage.txt", directory / "fs_usage.stderr"
        log_start = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(time.time() - 1))
        with raw.open("wb") as out, errors.open("wb") as err:
            tracer = subprocess.Popen(["sudo", "-n", "/usr/bin/fs_usage", "-e", "-w", "-f", "filesys",
                                       "-f", "network", "-f", "exec", "lsof", "pgrep", "sudo", "nettop"],
                                      stdout=out, stderr=err)
        samplers = Samplers(self.sanitize, self.listener.port)
        record = {"session": name}
        try:
            samplers.start()
            # Block-buffered output appears once system-wide events flow.
            deadline = time.monotonic() + 30
            while raw.stat().st_size == 0 and tracer.poll() is None and time.monotonic() < deadline:
                time.sleep(0.1)
            time.sleep(3)
            record["lead"] = self.ordinary("hg6-lead")
            try:
                record["workload"] = workload() if workload else None
            except Exception as error:  # Recorded as an invalid session, never a pass.
                record["workload"] = {"error": self.sanitize(repr(error))[:300]}
            record["trail"] = self.ordinary("hg6-trail")
            time.sleep(2)
        finally:
            sampled = samplers.finish()
            record["tracer_exit"] = self.stop_tracer(tracer, "fs_usage")
        log_end = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(time.time() + 1))
        stderr = errors.read_text(errors="replace")
        record["tracer_overrun"] = "buffer overrun" in stderr
        record["tracer_stderr"] = self.sanitize(stderr)[:600]
        record["fs_usage"] = parse_fs_usage(raw, self.sanitize)
        record.update(sampled)
        record["unified_log"] = unified_log(log_start, log_end, self.sanitize)
        record["log_window"] = [log_start, log_end]
        shutil.rmtree(directory)
        record["verdict"] = verdict(record, self.listener.port)
        (self.evidence / f"observation-{name}.json").write_text(json.dumps(record, indent=1, sort_keys=True))
        self.sessions.append(record)
        return record


def fs_group(record, name):
    return record["fs_usage"]["groups"].get(name, new_group())


def wrote_own_file(group, filename):
    opened = [entry for entry in group["writable_opens"]
              if entry["errno"] == 0 and entry["path"].endswith("/" + filename)]
    written = any(path.endswith("/" + filename) for path in group["write_fds_opened_writable"]) or any(
        path.endswith("/" + filename) for path in group["write_paths"])
    return bool(opened) and written


def connects(group, denied):
    # A denied attempt may surface at socket() or connect(); both are attempts.
    calls = ("connect ", "socket ") if denied else ("connect ",)
    return sum(count for key, count in group["network"].items()
               if key.startswith(calls) and (not key.endswith(" errno=0")) == denied)


def verdict(record, port):
    checks = {}
    for name in CONTROLS:
        key = "lead" if name == "hg6-lead" else "trail"
        control = record[key]
        group = fs_group(record, name)
        checks[f"{name}_ground_truth"] = (control["status"] == 0 and control["tcp_accepted"] >= 1
                                          and (control["file"] or "").startswith("tcp_connect=ok "))
        checks[f"{name}_traced_connect"] = connects(group, denied=False) >= 1
        checks[f"{name}_traced_write"] = wrote_own_file(group, f"{name}.written")
    checks["tracer_clean"] = record["tracer_exit"] == 0 and not record["tracer_overrun"]
    workload = record["workload"]
    session = record["session"]
    worker = fs_group(record, "worker")
    if workload and "error" in workload:
        checks["workload_completed"] = False
    elif session.startswith("launch-"):
        required = workload["mode"] == "required"
        control = workload["control"]
        expected = ("tcp_connect=os_error_1 ", "tcp_connect=os_error_13 ") if required else ("tcp_connect=ok ",)
        checks["launch_ground_truth"] = (workload.get("transcribe_status") not in (0, None)
                                         and workload.get("status_mode") == workload["mode"]
                                         and (control["file"] or "").startswith(expected)
                                         and (control["tcp_accepted"] == 0) == required)
        checks["launch_traced_connect"] = connects(worker, denied=required) >= 1
        checks["launch_traced_write"] = wrote_own_file(worker, "hagig-inference-worker.written")
        checks["helper_restored"] = workload["helper_restored"]
        checks["server_stopped"] = workload.get("stop_status") == 0 and workload.get("server_exit") == 0
    elif session.startswith("real-"):
        checks["workload_passed"] = workload["status"] == 0 and workload["stop_reap_pass"]
        checks["worker_model_load_traced"] = worker["open_paths"].get("encoder.int8.onnx", 0) >= 1
    secondary = {}
    reports = record["unified_log"]["sandbox_reports"].get("worker", {})
    lsof_worker = record["lsof"].get("worker", {})
    if session == "launch-required-control":
        secondary["seatbelt_report_control"] = any(k.startswith("deny network") for k in reports)
    if session.startswith("launch-"):
        secondary["lsof_control"] = bool(lsof_worker.get("network_fds")) and any(
            name.endswith(".written") for name in lsof_worker.get("writable_regular", {}))
    if session == "launch-disabled-control" or session == "tracer-smoke":
        secondary["nettop_listener_control"] = record["nettop"]["listener_samples"] >= 1
    secondary["lsof_ordinary_control"] = all(
        bool(record["lsof"].get(name, {}).get("network_fds")) for name in CONTROLS)
    observed = {
        "worker_network_syscalls": sum(worker["network"].values()),
        "worker_writable_opens": worker["writable_open_count"],
        "worker_mutations": sum(worker["mutations"].values()),
        "worker_writes_by_fd": worker["writes_by_fd"],
        "worker_writes_to_files_opened_writable": sum(worker["write_fds_opened_writable"].values()),
        "worker_seatbelt_reports": reports,
        "worker_lsof_samples": lsof_worker.get("samples", 0),
        "worker_lsof_network_fds": sum(lsof_worker.get("network_fds", {}).values()),
        "worker_lsof_writable_regular": sum(lsof_worker.get("writable_regular", {}).values()),
        "nettop_subject_samples": record["nettop"]["subject_samples"],
        "worker_unified_log_entries": sum(count for key, count in
                                          record["unified_log"]["process_log_entries"].items()
                                          if key.startswith("worker ")),
    }
    return {"valid": all(checks.values()), "checks": checks, "secondary_controls": secondary,
            "observed": observed}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path)
    parser.add_argument("--trace", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--smoke", action="store_true")
    args = parser.parse_args()
    args.trace.mkdir(mode=0o700)
    args.evidence = args.evidence.resolve(strict=True)
    if args.smoke:
        observation = Observation(args)
        sessions = [observation.session("tracer-smoke", None)]
    else:
        args.root = args.root.resolve(strict=True)
        observation = Observation(args)
        # From here a service may start; disposal then requires the cleanup marker.
        (args.evidence / "observation.command").write_text(" ".join(sys.argv[1:]) + "\n")
        sessions = []
        plan = [("launch-required-control", lambda: observation.launch_control("required")),
                ("real-required", lambda: observation.real("required")),
                ("real-disabled", lambda: observation.real("disabled")),
                ("launch-disabled-control", lambda: observation.launch_control("disabled"))]
        try:
            for name, workload in plan:
                sessions.append(observation.session(name, workload))
                if not observation.servers_stopped:
                    # Never start another service beside one whose stop is unproven.
                    break
        finally:
            live = subprocess.run(["/usr/bin/pgrep", "-f", str(args.root / "Contents/Helpers/")],
                                  capture_output=True, text=True).stdout.split()
            tracers = subprocess.run(["/usr/bin/pgrep", "-x", "fs_usage"], capture_output=True).returncode
            if observation.servers_stopped and not live and tracers != 0:
                (args.evidence / "observation-cleanup.txt").write_text("OBSERVATION_CLEANUP_COMPLETE\n")
    lines = []
    for record in sessions:
        result = record["verdict"]
        state = "VALID" if result["valid"] else "NOT OBSERVED / UNPROVEN"
        lines.append(f"SESSION {record['session']}: {state}")
        lines.append("  checks " + json.dumps(result["checks"], sort_keys=True))
        lines.append("  secondary_controls " + json.dumps(result["secondary_controls"], sort_keys=True))
        lines.append("  observed " + json.dumps(result["observed"], sort_keys=True))
    text = "\n".join(lines) + "\n"
    name = "observation-smoke-verdict.txt" if args.smoke else "observation-verdict.txt"
    (args.evidence / name).write_text(text)
    print(text, flush=True)
    if len(sessions) != (1 if args.smoke else 4) or not all(r["verdict"]["valid"] for r in sessions):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
