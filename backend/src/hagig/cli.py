"""Command-line interface (TDD section 9). Commands are stubs until #45."""

from pathlib import Path

import typer

app = typer.Typer(no_args_is_help=True, add_completion=False)
model_app = typer.Typer(no_args_is_help=True)
app.add_typer(model_app, name="model", help="Manage local models.")


def _not_implemented() -> None:
    typer.echo("not_implemented", err=True)
    raise typer.Exit(1)


@app.command()
def start() -> None:
    """Start or attach to the server."""
    _not_implemented()


@app.command()
def transcribe(audio: Path) -> None:
    """Transcribe a WAV file and print the text."""
    _not_implemented()


@app.command()
def status() -> None:
    """Report server status without starting it."""
    _not_implemented()


@app.command()
def stop() -> None:
    """Stop a running server."""
    _not_implemented()


@model_app.command("install")
def model_install(manifest_id: str) -> None:
    """Explicitly download and verify a model."""
    _not_implemented()
