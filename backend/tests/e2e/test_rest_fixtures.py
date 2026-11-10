"""Drive the real server with the shared REST fixtures (PROTOCOL.md, Shared fixtures).

Each server exchange is reproduced from its `given` state over the real
socket, sent byte for byte, and its status, listed headers and body checked.
"""

import json
import sys
import time
from pathlib import Path

import pytest

from hagig.contract import encode_json
from hagig.services.requests import RequestError, result_body
from tests.support.harness import LAST_CHUNK, TOKEN, RawConnection, chunk, wait_for

FIXTURES = json.loads(
    (Path(__file__).parents[1] / "fixtures" / "rest-v1-fixtures.json").read_text()
)
SERVER_EXCHANGES = [e for e in FIXTURES["exchanges"] if "server" in e["consumers"]]
FIXTURE_ID = "fixture-request-1"
FIXTURE_CONFIG = "fixture-config-1"


def request_bytes(exchange, request_id):
    request = exchange["request"]
    target = request["target"].replace(FIXTURE_ID, request_id)
    head = f"{request['method']} {target} HTTP/1.1\r\n"
    head += "".join(f"{name}: {value}\r\n" for name, value in request["headers"])
    head = (head + "\r\n").encode()
    body = request["body"]
    if "hex" in body:
        return head, [bytes.fromhex(body["hex"])], False
    if "chunks" in body:
        parts = [chunk(bytes.fromhex(c)) for c in body["chunks"]]
        if body.get("open"):
            return head, parts, True
        return head, [*parts, LAST_CHUNK], False
    if "repeat" in body:
        repeat = body["repeat"]
        data = bytes.fromhex(repeat["unit_hex"]) * repeat["count"]
        units = repeat.get("chunk_units")
        if units is None:
            return head, [data], False
        step = units * len(bytes.fromhex(repeat["unit_hex"]))
        return (
            head,
            [
                b"".join(chunk(data[i : i + step]) for i in range(0, len(data), step))
                + LAST_CHUNK
            ],
            False,
        )
    return head, [], False


def sent_audio(exchange):
    body = exchange["request"]["body"]
    if "hex" in body:
        return bytes.fromhex(body["hex"])
    if "chunks" in body:
        return b"".join(bytes.fromhex(c) for c in body["chunks"])
    if "repeat" in body:
        return bytes.fromhex(body["repeat"]["unit_hex"]) * body["repeat"]["count"]
    return b""


def engine_control(engine):
    if engine == "crash":
        return {"behavior": "crash"}
    if engine == "stall":
        return {"behavior": "stall"}
    return engine


def server_options(given):
    options = {"deadlines": {}}
    if given.get("engine") == "stall":
        options["deadlines"]["computation"] = 0.5
    if given.get("during_upload") == "reservation_deadline":
        options["deadlines"]["reservation"] = 0.5
    if given.get("state") == "upload_start_expired":
        options["deadlines"]["upload_start"] = 0.2
    if given.get("state") == "stopping":
        options["hold_file"] = "/nonexistent-hold-file"
    if given.get("isolation") == "unavailable" and sys.platform == "darwin":
        # Linux refuses required mode for real; macOS needs a launcher that cannot.
        options["sandbox_exec"] = "/nonexistent/sandbox-exec"
    return options


def check_response(exchange, actual):
    status, headers, body = actual
    expected = exchange["response"]
    assert status == expected["status"]
    names = {name.lower(): value for name, value in headers}
    variable = exchange.get("server_variable", [])
    for name, value in expected["headers"]:
        if name == "content-length" and variable:
            assert names[name] == str(len(body))
        else:
            assert names.get(name.lower()) == value, name
    if expected["body"].get("empty"):
        assert body == b""
        return
    want = bytes.fromhex(expected["body"]["hex"])
    if variable:
        document = json.loads(body)
        for pointer in variable:
            value = document[pointer.lstrip("/")]
            assert TOKEN.fullmatch(value)
            placeholder = expected["body"]["json"][pointer.lstrip("/")]
            body = body.replace(
                json.dumps(value).encode(), json.dumps(placeholder).encode()
            )
    assert body == want


@pytest.mark.parametrize("exchange", SERVER_EXCHANGES, ids=lambda e: e["name"])
def test_server_exchange(exchange, home):
    given = exchange["given"]
    home.write_config(isolation=given.get("network_isolation", "disabled"))
    if given.get("model", "installed") != "missing":
        home.install_model(corrupt=given.get("model") == "corrupt")
    home.start_server(**server_options(given))

    if given.get("worker") == "running":
        assert home.transcribe(bytes(8)).status_code == 200
    engine = given.get("engine")
    if engine is not None:
        home.engine(**engine_control(engine))

    state = given.get("state", "idle")
    request_id = FIXTURE_ID
    first_upload = None
    if state in ("reserved", "uploading", "upload_start_expired"):
        request_id = home.admit()
    if state == "uploading":
        first_upload = RawConnection(home.socket)
        first_upload.send(
            f"PUT /v1/requests/{request_id}/audio HTTP/1.1\r\nHost: localhost\r\n"
            "Content-Type: application/octet-stream\r\n"
            "Transfer-Encoding: chunked\r\n\r\n".encode()
            + chunk(bytes(4))
        )
        wait_for(lambda: home.status()["state"] == "busy")
        time.sleep(0.1)
    if state == "upload_start_expired":
        time.sleep(0.5)
    if state == "stopping":
        with home.client() as client:
            assert client.post("/v1/stop").status_code == 202

    head, parts, still_open = request_bytes(exchange, request_id)
    connection = RawConnection(home.socket)
    connection.send(head)
    for part in parts:
        if not connection.send(part):
            break
        if len(parts) > 1:
            # Pause so the server receives each chunk as its own message;
            # otherwise uvicorn may merge them and no boundary is exercised.
            time.sleep(0.02)
    if still_open:
        during = given["during_upload"]
        time.sleep(0.1)
        if during == "delete":
            with home.client() as client:
                assert client.delete(f"/v1/requests/{request_id}").status_code == 204
        elif during == "stop":
            with home.client() as client:
                assert client.post("/v1/stop").status_code == 202
    actual = connection.response()
    check_response(exchange, actual)

    expected_headers = {n.lower(): v for n, v in exchange["response"]["headers"]}
    if expected_headers.get("connection") == "close":
        assert connection.closed_by_peer()
    connection.close()

    if exchange["request"]["method"] == "PUT" and actual[0] == 200:
        # The engine received exactly the body bytes.
        assert home.record("audio", home.pids()[-1], ".bin") == sent_audio(exchange)
    if first_upload is not None:
        # The rejected second upload did not disturb the first.
        first_upload.send(LAST_CHUNK)
        assert first_upload.response()[0] == 200
        first_upload.close()


def test_fixture_set_covers_every_error_code_the_server_sends():
    sent = {
        json.loads(bytes.fromhex(e["response"]["body"]["hex"]))["code"]
        for e in SERVER_EXCHANGES
        if e["response"]["status"] >= 400
    }
    assert sent == {entry["code"] for entry in FIXTURES["error_codes"]}


@pytest.mark.parametrize("case", FIXTURES["result_size_cases"], ids=lambda c: c["name"])
def test_result_size_cases(case):
    text = case["text_repeat"]["unit"] * case["text_repeat"]["count"]
    assert len(encode_json({"text": text})) == case["rest_body_bytes"]
    if case["fits"]:
        assert result_body(text) == encode_json({"text": text})
    else:
        with pytest.raises(RequestError) as failure:
            result_body(text)
        assert (failure.value.code, failure.value.status) == ("result_too_large", 500)
