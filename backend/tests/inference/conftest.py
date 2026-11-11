"""Opt-in real-engine evidence on macOS (#49).

Runs only when `HAGIG_INFERENCE_DATA` names an absolute XDG data directory
holding installed `qwen3-asr-0.6b` and `whisper-large-v3-turbo` models
(`hagig model install`), on macOS with both engine extras synced. Otherwise
every test here is skipped. These tests use the network on purpose (the
isolation probe's unsandboxed control) and are not part of the portable suite.
"""

import os
import sys
from pathlib import Path

import pytest

from tests.inference.stack import Stack
from tests.support.harness import short_runtime_base

DATA = os.environ.get("HAGIG_INFERENCE_DATA", "")


@pytest.fixture(autouse=True)
def _real_engines_only():
    if not DATA:
        pytest.skip("set HAGIG_INFERENCE_DATA to run the real-engine evidence")
    if not DATA.startswith("/") or sys.platform != "darwin":
        pytest.skip("real-engine evidence needs macOS and an absolute data directory")


@pytest.fixture
def stack(tmp_path):
    with short_runtime_base() as runtime:
        user = Stack(tmp_path, runtime, Path(DATA))
        try:
            yield user
        finally:
            user.cleanup()
