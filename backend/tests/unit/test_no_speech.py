"""The two no-speech guards (PROTOCOL.md, Result text).

Expected values are worked out by hand from the stated rules (-60 dBFS is
10**(-60/20) = 0.001; the vocabulary is read back as case-folded words), not
taken from the code under test.
"""

import asyncio
import struct
from pathlib import Path

import pytest

from hagig.config import Config
from hagig.launcher import Launcher
from hagig.manifest import load_manifest
from hagig.services.requests import (
    AudioValidator,
    Deadlines,
    DisconnectedError,
    RequestError,
    RequestService,
    echoes_vocabulary,
    is_silent,
)
from hagig.services.supervisor import Supervisor, WorkerSettings


def f32(*samples):
    return struct.pack(f"<{len(samples)}f", *samples)


def peak_of(*chunks):
    validator = AudioValidator()
    for chunk in chunks:
        validator.feed(chunk)
    validator.finish()
    return validator.peak


def test_the_peak_is_the_largest_absolute_sample_across_chunks():
    assert peak_of(f32(0.0, -0.5), f32(0.25)) == 0.5
    # A sample split across chunks counts, and the sign does not matter.
    data = f32(0.1, -0.75, 0.2)
    assert peak_of(data[:5], data[5:9], data[9:]) == 0.75
    assert peak_of(f32(-0.0, 0.0)) == 0.0


@pytest.mark.parametrize(
    ("samples", "silent"),
    [
        ((0.0,) * 16000, True),  # all zero
        ((0.00099, -0.00099), True),  # just below -60 dBFS, either sign
        ((0.00101,), False),  # just above
        ((-0.00101,), False),
        ((0.0,) * 15999 + (0.5,), False),  # silent except for one sample
        ((0.0,) * 15999 + (-0.002,), False),
    ],
)
def test_the_floor_is_minus_60_dbfs_of_the_peak(samples, silent):
    assert is_silent(peak_of(f32(*samples))) is silent


TERMS = ["Hagig", "Ghostty", "Qwen", "Amp"]


@pytest.mark.parametrize(
    "text",
    [
        "Hagig, Ghostty, Qwen, Amp.",  # the Qwen prompt's terms, echoed
        "Vocabulary: Hagig, Ghostty, Qwen, Amp.",
        "hagig ghostty qwen amp",
        "  HAGIG;  ghostty -- QWEN... amp!\n",
        "vocabulary Hagig Ghostty Qwen Amp",
    ],
)
def test_an_echo_of_the_vocabulary_is_no_speech(text):
    assert echoes_vocabulary(text, TERMS)


@pytest.mark.parametrize(
    "text",
    [
        "Hagig, Ghostty, Qwen, Amp, and more.",  # a real sentence around them
        "I use Hagig, Ghostty, Qwen, Amp every day",
        "Hagig, Ghostty, Qwen.",  # strict prefix
        "Ghostty, Qwen, Amp.",  # strict suffix
        "Ghostty, Hagig, Qwen, Amp.",  # reordered
        "Amp, Qwen, Ghostty, Hagig.",
        "Hagig, Ghostty, Qwen, Amp, Amp.",  # repeated
        "Vocabulary: Hagig, Ghostty, Qwen.",
        "Vocabulary Vocabulary Hagig Ghostty Qwen Amp",
        "Thank you.",
        "",
        "Vocabulary:",
    ],
)
def test_other_text_is_not_an_echo(text):
    assert not echoes_vocabulary(text, TERMS)


def test_a_single_term_vocabulary():
    assert echoes_vocabulary("Hagig.", ["Hagig"])
    assert echoes_vocabulary("Vocabulary: hagig", ["Hagig"])
    assert not echoes_vocabulary("Hagig is great.", ["Hagig"])
    assert not echoes_vocabulary("Vocabulary.", ["Hagig"])


def test_an_empty_vocabulary_never_matches():
    for text in ["", "Vocabulary:", "Vocabulary: .", "Thank you."]:
        assert not echoes_vocabulary(text, [])
    # A term with no letters or digits is no vocabulary either.
    assert not echoes_vocabulary("Vocabulary", ["..."])


def test_multi_word_terms_match_across_their_own_punctuation():
    terms = ["Ghostty-secret-term", "New York"]
    assert echoes_vocabulary("Vocabulary: Ghostty secret term, New York.", terms)
    assert not echoes_vocabulary("Ghostty secret term.", terms)


# The service through its public methods. Its supervisor points at a model
# that is not installed, so being asked to transcribe at all is `model_missing`.

SILENT = f32(*([0.0] * 1600))
AUDIBLE = f32(0.0, 0.25)


def service():
    config = Config.model_validate({"model": {"id": "qwen3-asr-0.6b"}})
    settings = WorkerSettings(
        launcher=Launcher(),
        mode="disabled",
        env={},
        models_root=Path("/nonexistent"),
        manifest=load_manifest("qwen3-asr-0.6b"),
        vocabulary=(),
    )
    return RequestService(config, Supervisor(settings), Deadlines())


def upload(body, after_body=None):
    """Upload `body`; `after_body(service, request_id)` runs on the next receive.

    Returns the response bytes or the exception raised, and the service's status
    and whether the slot could be admitted again, taken once the upload ended.
    """
    svc = service()

    async def go():
        request_id = svc.admit()["request_id"]
        messages = [{"type": "http.request", "body": body, "more_body": False}]

        async def receive():
            if messages:
                return messages.pop()
            if after_body is not None:
                return await after_body(svc, request_id)
            await asyncio.Event().wait()

        try:
            response = await svc.upload(
                request_id, "application/octet-stream", None, receive
            )
        except (RequestError, DisconnectedError) as error:
            response = error
        status = svc.status()
        return response, status, bool(svc.admit())

    return asyncio.run(go())


def test_silent_audio_is_answered_without_asking_the_worker():
    response, status, _ = upload(SILENT)
    assert response == b'{"text":""}'
    assert status["worker"] == "absent"


def test_audible_audio_still_reaches_the_supervisor():
    response, _status, _ = upload(AUDIBLE)
    assert isinstance(response, RequestError)
    assert response.code == "model_missing"


def test_a_cancel_racing_the_early_no_speech_wins_and_frees_the_slot():
    async def cancel(svc, request_id):
        svc.cancel(request_id)
        await asyncio.Event().wait()

    response, status, readmitted = upload(SILENT, cancel)
    assert isinstance(response, RequestError)
    assert (response.code, response.status) == ("cancelled", 409)
    assert status["state"] == "idle"
    assert readmitted


def test_a_disconnect_racing_the_early_no_speech_delivers_no_response():
    async def disconnect(_svc, _request_id):
        return {"type": "http.disconnect"}

    response, status, readmitted = upload(SILENT, disconnect)
    assert isinstance(response, DisconnectedError)
    assert status["state"] == "idle"
    assert readmitted
