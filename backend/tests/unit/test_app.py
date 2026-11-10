import asyncio
import logging

from hagig.app import create_app


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
        sent = run_lifespan(create_app())
    assert sent == ["lifespan.startup.complete", "lifespan.shutdown.complete"]
    assert [r for r in caplog.records if r.name.startswith("fastapi")] == []
