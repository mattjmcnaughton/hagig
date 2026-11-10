"""The worker's side of the pipe protocol, driven through `run` with byte streams."""

import io
import json
import struct

import pytest

from hagig.worker import EngineError, run

READY = b"HAGIG-WORKER-READY-v1\n"


def frame(kind, payload):
    return struct.pack(">BI", kind, len(payload)) + payload


def msg(**fields):
    return frame(1, json.dumps(fields, separators=(",", ":")).encode())


def load(generation=1, **overrides):
    fields = {
        "type": "load",
        "version": 1,
        "generation": generation,
        "engine": "e",
        "model_dir": "/models/m",
        "vocabulary": ["Hagig", "Amp"],
    }
    fields.update(overrides)
    return msg(**fields)


def transcribe(pcm, generation=1, request_id="r-1"):
    return msg(
        type="transcribe",
        generation=generation,
        request_id=request_id,
        sample_count=len(pcm) // 4,
    ) + frame(2, pcm)


def replies(out):
    """Parse everything after the ready line into (kind, decoded) frames."""
    data = out.getvalue()
    assert data.startswith(READY)
    data = data[len(READY) :]
    frames = []
    while data:
        kind, length = struct.unpack(">BI", data[:5])
        frames.append((kind, json.loads(data[5 : 5 + length])))
        data = data[5 + length :]
    return frames


class Recorder:
    def __init__(self, out=None, text="Fixture."):
        self.out = out
        self.text = text
        self.loaded = None
        self.calls = []

    def load(self, model_dir):
        self.loaded = model_dir

    def transcribe(self, audio, vocabulary):
        self.calls.append((audio.tobytes(), audio.dtype.str, tuple(vocabulary)))
        return self.text


def serve(stdin_bytes, engines):
    out = io.BytesIO()
    status = run(io.BytesIO(stdin_bytes), out, engines)
    return status, out


PCM = struct.pack("<3f", 0.0, -1.0, 1.0)


def test_ready_line_precedes_engine_construction_and_only_selected_engine_loads():
    seen = {}
    out = io.BytesIO()
    engine = Recorder()

    def construct():
        seen["stdout_at_construction"] = out.getvalue()
        return engine

    def other():
        raise AssertionError("unselected engine constructed")

    status = run(
        io.BytesIO(load() + transcribe(PCM)), out, {"e": construct, "other": other}
    )
    assert status == 0
    assert seen["stdout_at_construction"] == READY
    assert str(engine.loaded) == "/models/m"
    assert engine.calls == [(PCM, "<f4", ("Hagig", "Amp"))]
    assert replies(out) == [
        (1, {"type": "loaded", "generation": 1}),
        (
            1,
            {
                "type": "result",
                "generation": 1,
                "request_id": "r-1",
                "text": "Fixture.",
            },
        ),
    ]


def test_warm_worker_serves_several_requests_until_stdin_closes():
    engine = Recorder()
    status, out = serve(
        load(generation=7) + transcribe(PCM, 7, "a") + transcribe(PCM[:4], 7, "b"),
        {"e": lambda: engine},
    )
    assert status == 0
    assert [f[1].get("request_id") for f in replies(out)] == [None, "a", "b"]
    assert [f[1]["generation"] for f in replies(out)] == [7, 7, 7]


@pytest.mark.parametrize(
    ("raised", "code"),
    [
        (EngineError("model_missing"), "model_missing"),
        (EngineError("model_invalid"), "model_invalid"),
        (EngineError("something_else"), "worker_failed"),
        (RuntimeError("boom with secret path /x"), "worker_failed"),
    ],
)
def test_load_failures_reply_error_with_null_request_id(raised, code):
    class Failing(Recorder):
        def load(self, model_dir):
            raise raised

    status, out = serve(load(), {"e": Failing})
    assert status == 1
    assert replies(out) == [
        (
            1,
            {"type": "error", "generation": 1, "request_id": None, "code": code},
        )
    ]


@pytest.mark.parametrize(
    "bad_load",
    [load(version=2), load(engine="unknown")],
    ids=["version", "engine"],
)
def test_unsupported_version_or_engine_is_worker_failed(bad_load):
    status, out = serve(bad_load, {"e": Recorder})
    assert status == 1
    assert replies(out)[0][1]["code"] == "worker_failed"


def test_engine_import_failure_from_the_real_table_is_worker_failed():
    from hagig.worker import ENGINES

    # The real engines arrive with #49; selecting one now must fail cleanly.
    status, out = serve(load(engine="qwen3-asr"), ENGINES)
    assert status == 1
    assert replies(out)[0][1]["code"] == "worker_failed"


def result_envelope_bytes(text):
    return len(
        json.dumps(
            {"type": "result", "generation": 1, "request_id": "r-1", "text": text},
            ensure_ascii=False,
            separators=(",", ":"),
        ).encode()
    )


def test_result_frame_cap_is_exact():
    base = result_envelope_bytes("")
    at_limit = "a" * (65_536 - base)
    status, out = serve(
        load() + transcribe(PCM), {"e": lambda: Recorder(text=at_limit)}
    )
    assert replies(out)[-1][1]["text"] == at_limit

    over = "λ" * ((65_536 - base) // 2 + 1)
    assert result_envelope_bytes(over) > 65_536
    status, out = serve(load() + transcribe(PCM), {"e": lambda: Recorder(text=over)})
    assert status == 1
    assert replies(out)[-1][1] == {
        "type": "error",
        "generation": 1,
        "request_id": "r-1",
        "code": "result_too_large",
    }


@pytest.mark.parametrize("text", ["\ud800", b"bytes"], ids=["surrogate", "not-str"])
def test_unencodable_result_is_worker_failed(text):
    status, out = serve(load() + transcribe(PCM), {"e": lambda: Recorder(text=text)})
    assert status == 1
    assert replies(out)[-1][1]["code"] == "worker_failed"


def test_engine_exception_during_transcribe_is_worker_failed():
    class Crashing(Recorder):
        def transcribe(self, audio, vocabulary):
            raise ValueError("content")

    status, out = serve(load() + transcribe(PCM), {"e": Crashing})
    assert status == 1
    assert replies(out)[-1][1] == {
        "type": "error",
        "generation": 1,
        "request_id": "r-1",
        "code": "worker_failed",
    }


def test_wrong_generation_or_sample_count_is_refused():
    status, out = serve(load() + transcribe(PCM, generation=2), {"e": Recorder})
    assert (status, replies(out)[-1][1]["code"]) == (1, "worker_failed")

    bad_count = msg(
        type="transcribe", generation=1, request_id="r-1", sample_count=2
    ) + frame(2, PCM)
    status, out = serve(load() + bad_count, {"e": Recorder})
    assert (status, replies(out)[-1][1]["code"]) == (1, "worker_failed")


@pytest.mark.parametrize(
    "stream",
    [
        frame(3, b"{}"),
        frame(2, PCM),
        struct.pack(">BI", 1, 0),
        struct.pack(">BI", 1, 65_537),
        struct.pack(">BI", 1, 10) + b"{}",
        b"\x01\x00",
        frame(1, b'{"type":"load","type":"load"}'),
        frame(1, b"\xff\xfe"),
        frame(1, b"[" * 100_000),
        frame(1, b"not json"),
    ],
    ids=[
        "unknown-kind",
        "pcm-first",
        "empty-json",
        "oversized-json",
        "eof-mid-payload",
        "eof-mid-header",
        "duplicate-key",
        "invalid-utf8",
        "deep-nesting",
        "not-json",
    ],
)
def test_malformed_input_exits_without_replying(stream):
    status, out = serve(stream, {"e": Recorder})
    assert status == 1
    assert out.getvalue() == READY


def test_pcm_frame_must_follow_transcribe_with_valid_length():
    request = msg(type="transcribe", generation=1, request_id="r-1", sample_count=1)
    for bad in [frame(1, b"{}"), struct.pack(">BI", 2, 3) + b"abc"]:
        status, out = serve(load() + request + bad, {"e": Recorder})
        assert status == 1
        assert [f[1]["type"] for f in replies(out)] == ["loaded"]


def test_eof_before_load_exits_cleanly():
    status, out = serve(b"", {"e": Recorder})
    assert (status, out.getvalue()) == (0, READY)
