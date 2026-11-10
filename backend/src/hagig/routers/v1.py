"""REST API v1 (backend/PROTOCOL.md, Endpoints).

`Precedence` applies the contract's first two rules to every request before
FastAPI routes it: an unknown path or method is `400 invalid_request`, and a
body on any endpoint but PUT is refused from its headers alone, unread, with
`Connection: close`. The handlers apply the rest: DELETE and stop always
succeed, then the service raises `server_stopping`, then each endpoint's rules.
"""

from collections.abc import Sequence
from typing import Any

from fastapi import APIRouter, Request, Response
from starlette.routing import BaseRoute, Route
from starlette.types import ASGIApp, Receive, Scope, Send

from hagig.contract import encode_json
from hagig.services.requests import DisconnectedError, RequestError, RequestService

_CLOSE = {"connection": "close"}


def json_response(
    status: int, body: dict[str, Any], headers: dict[str, str] | None = None
) -> Response:
    return Response(encode_json(body), status, headers, "application/json")


def error_response(code: str, status: int = 400, close: bool = False) -> Response:
    return json_response(status, {"code": code}, _CLOSE if close else None)


class Precedence:
    """Pure ASGI middleware for the contract's routing and body rules."""

    def __init__(self, app: ASGIApp, routes: Sequence[BaseRoute]) -> None:
        self.app = app
        self.routes = routes

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        response = None
        if not _known(self.routes, scope["method"], scope["path"]):
            response = error_response("invalid_request", close=_has_body(scope))
        elif scope["method"] != "PUT" and _has_body(scope):
            response = error_response("invalid_request", close=True)
        if response is None:
            await self.app(scope, receive, send)
        else:
            await response(scope, receive, send)


def _known(routes: Sequence[BaseRoute], method: str, path: str) -> bool:
    # fullmatch, not Starlette's `^...$` match, whose `$` also matches before
    # a trailing newline (`/v1/stop%0A`). A wrong method is unknown too.
    return any(
        isinstance(route, Route)
        and method in (route.methods or ())
        and route.path_regex.fullmatch(path) is not None
        for route in routes
    )


def _has_body(scope: Scope) -> bool:
    for name, value in scope["headers"]:
        if name == b"transfer-encoding":
            return True
        if name == b"content-length" and value.strip() != b"0":
            return True
    return False


def _content_length(request: Request) -> int | None:
    value = request.headers.get("content-length", "").strip()
    # uvicorn has already rejected malformed values.
    return int(value) if value.isdigit() else None


def create_router(service: RequestService) -> APIRouter:
    router = APIRouter()

    @router.get("/v1/status")
    async def status() -> Response:
        try:
            return json_response(200, service.status())
        except RequestError as failure:
            return error_response(failure.code, failure.status)

    @router.post("/v1/requests")
    async def admit() -> Response:
        try:
            return json_response(201, service.admit())
        except RequestError as failure:
            return error_response(failure.code, failure.status)

    @router.put("/v1/requests/{request_id}/audio")
    async def upload(request_id: str, request: Request) -> Response:
        try:
            body = await service.upload(
                request_id,
                request.headers.get("content-type"),
                _content_length(request),
                request.receive,
            )
        except RequestError as failure:
            return error_response(failure.code, failure.status, close=True)
        except DisconnectedError:
            # Nobody is listening; uvicorn drops a response to a closed peer.
            return Response(status_code=204, headers=_CLOSE)
        return Response(body, 200, _CLOSE, "application/json")

    @router.delete("/v1/requests/{request_id}", status_code=204)
    async def cancel(request_id: str) -> Response:
        service.cancel(request_id)
        return Response(status_code=204)

    @router.post("/v1/stop", status_code=202)
    async def stop() -> Response:
        service.stop()
        return Response(status_code=202)

    return router
