"""FastAPI application factory (TDD section 6; backend/PROTOCOL.md)."""

from fastapi import FastAPI, Request, Response
from fastapi.exceptions import RequestValidationError
from starlette.exceptions import HTTPException

from hagig.routers.v1 import Precedence, create_router, error_response
from hagig.services.requests import RequestService


async def _invalid_request(_request: Request, _error: Exception) -> Response:
    # FastAPI's defaults echo rejected input; `Precedence` should make these
    # unreachable, but any that slip through stay content-free.
    return error_response("invalid_request")


def create_app(service: RequestService) -> FastAPI:
    """Create the FastAPI application for one server lifetime."""
    app = FastAPI(
        # TDD section 6: no documentation or OpenAPI routes.
        docs_url=None,
        redoc_url=None,
        openapi_url=None,
        # A trailing slash is an unknown path, never a redirect.
        redirect_slashes=False,
        # FastAPI's native OpenTelemetry stays off, whatever the environment says.
        telemetry={
            "tracing": False,
            "metrics": False,
            "logs": False,
            "operation_spans": False,
            "auto_configure": False,
        },
    )
    app.add_exception_handler(HTTPException, _invalid_request)
    app.add_exception_handler(RequestValidationError, _invalid_request)
    router = create_router(service)
    app.include_router(router)
    app.add_middleware(Precedence, routes=router.routes)
    return app
