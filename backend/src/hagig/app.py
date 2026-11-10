"""FastAPI application factory. Routes arrive with #45."""

from fastapi import FastAPI


def create_app() -> FastAPI:
    """Create the FastAPI application."""
    return FastAPI(
        # TDD section 6: no documentation or OpenAPI routes.
        docs_url=None,
        redoc_url=None,
        openapi_url=None,
        # FastAPI's native OpenTelemetry stays off, whatever the environment says.
        telemetry={
            "tracing": False,
            "metrics": False,
            "logs": False,
            "operation_spans": False,
            "auto_configure": False,
        },
    )
