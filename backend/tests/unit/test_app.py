import asyncio
import logging
from pathlib import Path

from hagig.app import create_app
from hagig.config import Config
from hagig.launcher import Launcher
from hagig.manifest import load_manifest
from hagig.services.requests import Deadlines, RequestService
from hagig.services.supervisor import Supervisor, WorkerSettings


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


def run_lifespan(app):
    messages = [{"type": "lifespan.startup"}, {"type": "lifespan.shutdown"}]
    sent = []

    async def receive():
        return messages.pop(0)

    async def send(message):
        sent.append(message["type"])

    scope = {"type": "lifespan", "asgi": {"version": "3.0"}, "state": {}}
    asyncio.run(app(scope, receive, send))
    return sent


def test_fastapi_telemetry_ignores_environment_auto_configuration(monkeypatch, caplog):
    monkeypatch.setenv("FASTAPI_OTEL_AUTO_CONFIGURE", "true")
    monkeypatch.setenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://127.0.0.1:9")
    with caplog.at_level(logging.DEBUG, logger="fastapi"):
        sent = run_lifespan(create_app(service()))
    assert sent == ["lifespan.startup.complete", "lifespan.shutdown.complete"]
    assert [r for r in caplog.records if r.name.startswith("fastapi")] == []
