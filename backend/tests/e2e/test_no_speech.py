"""No-speech answers through the real server with the fake engine.

The fake engine would answer "Fixture." (or the scripted text) to anything it is
sent, so a `{"text":""}` here is the server's own doing. The test configuration's
vocabulary is `VOCABULARY` ("Hagig", "Ghostty-secret-term").
"""

import struct

import pytest

from tests.support.harness import pid_alive

NO_SPEECH = (200, {"text": ""})


def f32(*samples):
    return struct.pack(f"<{len(samples)}f", *samples)


def answer(response):
    return response.status_code, response.json()


@pytest.mark.parametrize(
    "samples",
    [
        (0.0,) * 16000,
        (0.00099, -0.00099, 0.0),
    ],
    ids=["all-zero", "just-below-the-floor"],
)
def test_audio_with_no_signal_is_no_speech_without_a_worker(server, samples):
    server.engine(text="Fixture.")
    assert answer(server.transcribe(f32(*samples))) == NO_SPEECH
    assert server.pids() == []
    assert server.status()["worker"] == "absent"
    assert server.status()["state"] == "idle"


@pytest.mark.parametrize(
    "samples",
    [
        (0.00101,),
        (-0.00101,),
        (0.0,) * 15999 + (0.5,),
    ],
    ids=["just-above-the-floor", "negative-just-above", "one-loud-sample"],
)
def test_audio_with_any_signal_reaches_the_engine(server, samples):
    server.engine(text="Fixture.")
    assert answer(server.transcribe(f32(*samples))) == (200, {"text": "Fixture."})
    assert len(server.pids()) == 1


def test_silence_does_not_disturb_a_warm_worker(server):
    server.engine(text="Fixture.")
    assert server.transcribe(f32(0.5)).status_code == 200
    (pid,) = server.pids()
    assert answer(server.transcribe(f32(0.0, 0.0))) == NO_SPEECH
    assert server.pids() == [pid] and pid_alive(pid)
    assert answer(server.transcribe(f32(0.5))) == (200, {"text": "Fixture."})
    assert server.pids() == [pid]


def test_silence_is_checked_before_the_model_and_isolation(home):
    # Decision: no worker is launched, so the launch-time checks (missing,
    # isolation, installation) do not run. Audible audio still gets them.
    home.write_config(isolation="required")
    home.start_server(platform="linux")
    assert answer(home.transcribe(f32(0.0, 0.0))) == NO_SPEECH
    assert answer(home.transcribe(f32(0.5))) == (503, {"code": "model_missing"})


@pytest.mark.parametrize(
    "text",
    [
        "Hagig, Ghostty-secret-term.",
        "Vocabulary: Hagig, Ghostty-secret-term.",
        "HAGIG... ghostty secret term!",
    ],
)
def test_an_echo_of_the_vocabulary_is_no_speech(server, text):
    server.engine(text=text)
    assert answer(server.transcribe(f32(0.5, -0.25))) == NO_SPEECH
    # The engine did run: this is the model's answer being replaced.
    assert len(server.pids()) == 1


@pytest.mark.parametrize(
    "text",
    [
        "Hagig and Ghostty-secret-term are tools.",
        "Hagig.",  # a strict prefix
        "Ghostty-secret-term, Hagig.",  # reordered
        "Thank you.",
        "Vocabulary:",
    ],
)
def test_other_text_passes_through_unchanged(server, text):
    server.engine(text=text)
    assert answer(server.transcribe(f32(0.5, -0.25))) == (200, {"text": text})


def test_an_empty_vocabulary_filters_nothing(home):
    home.write_config(terms=[])
    home.install_model()
    home.start_server()
    for text in ["Vocabulary:", "Vocabulary: .", "Hagig."]:
        home.engine(text=text)
        assert answer(home.transcribe(f32(0.5))) == (200, {"text": text})


def test_a_single_term_vocabulary(home):
    home.write_config(terms=["Hagig"])
    home.install_model()
    home.start_server()
    home.engine(text="Vocabulary: Hagig.")
    assert answer(home.transcribe(f32(0.5))) == NO_SPEECH
    home.engine(text="Hagig works.")
    assert answer(home.transcribe(f32(0.5))) == (200, {"text": "Hagig works."})


def test_the_filters_leave_no_content_in_the_server_log(server):
    server.engine(text="Vocabulary: Hagig, Ghostty-secret-term.")
    assert answer(server.transcribe(f32(0.5))) == NO_SPEECH
    assert answer(server.transcribe(f32(0.0))) == NO_SPEECH
    logs = server.server_logs()
    for secret in [b"Ghostty-secret-term", b"Vocabulary"]:
        assert secret not in logs
