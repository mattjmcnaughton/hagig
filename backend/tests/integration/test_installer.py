"""`hagig.installer` against a local HTTP fixture server (no network)."""

import os
import signal
import subprocess
import sys
import threading
import time

import httpx
import pytest

from hagig.installer import InstallError, install
from hagig.models import (
    LOCK_NAME,
    ModelError,
    current_version,
    installed_model,
    verify_installation,
)
from tests.support.models import (
    CONFIG,
    CONVERTER,
    FILES,
    REVISION,
    WEIGHTS,
    FixtureServer,
    Route,
    serve,
    sha256,
)

OTHER_REVISION = "c" * 40


def allow_local(url: httpx.URL) -> bool:
    return url.scheme == "http" and url.host == "127.0.0.1"


@pytest.fixture
def server():
    fixture = FixtureServer()
    yield fixture
    fixture.close()


@pytest.fixture
def client():
    with httpx.Client(trust_env=False, follow_redirects=False) as http:
        yield http


@pytest.fixture
def models(tmp_path):
    return tmp_path / "data" / "hagig" / "models"


@pytest.fixture
def run(models, client, tmp_path):
    env = {"HOME": str(tmp_path), "PATH": "/usr/bin:/bin"}

    def run(manifest, **options):
        options.setdefault("apple_silicon", True)
        options.setdefault("allow", allow_local)
        return install(manifest, models, client=client, env=env, **options)

    return run


def failure(run, manifest, **options) -> InstallError:
    with pytest.raises(InstallError) as caught:
        run(manifest, **options)
    error = caught.value
    # Content-free: the code and at most a manifest file name.
    assert error.__cause__ is None and error.__context__ is None
    return error


def leftovers(models):
    """Anything an install left besides the lock and published versions."""
    found = []
    for path in models.rglob("*"):
        relative = path.relative_to(models)
        if relative.parts[0].startswith(".staging-") or ".current-" in path.name:
            found.append(relative)
    return found


def assert_published(models, manifest, files):
    version = installed_model(models, manifest)
    verify_installation(version)
    for name, data in files.items():
        assert (version / name).read_bytes() == data
    return version


# Success paths.


def test_install_downloads_only_the_allowlist_and_publishes(server, run, models):
    server.routes["/test/model/resolve/" + REVISION + "/pytorch_model.bin"] = Route(
        body=b"pickle"
    )
    manifest = serve(server)

    assert run(manifest) == "installed"

    version = assert_published(models, manifest, FILES)
    assert version.parent == models / manifest.id
    assert os.readlink(models / manifest.id / "current") == version.name
    assert sorted(p.name for p in version.iterdir()) == [
        "config.json",
        "hagig-install.json",
        "model.safetensors",
    ]
    assert sorted(server.requests) == sorted(
        f"/test/model/resolve/{REVISION}/{name}" for name in FILES
    )
    assert leftovers(models) == []
    assert (models / LOCK_NAME).is_file()


def test_a_valid_installation_is_not_downloaded_again(server, run, models):
    manifest = serve(server)
    run(manifest)
    first = current_version(models, manifest.id)
    server.requests.clear()

    assert run(manifest) == "already_installed"

    assert server.requests == []
    assert current_version(models, manifest.id) == first


def test_a_corrupt_installation_is_replaced_and_pruned(server, run, models):
    manifest = serve(server)
    run(manifest)
    old = current_version(models, manifest.id)
    assert old is not None
    weights = old / "model.safetensors"
    weights.write_bytes(b"X" + WEIGHTS[1:])

    assert run(manifest) == "installed"

    new = assert_published(models, manifest, FILES)
    assert new != old and not old.exists()
    assert sorted(p.name for p in new.parent.iterdir()) == ["current", new.name]


def test_same_host_redirects_are_followed(server, run, models):
    manifest = serve(server)
    path = f"/test/model/resolve/{REVISION}/model.safetensors"
    server.routes["/cdn/weights"] = server.routes[path]
    server.routes[path] = Route(status=302, location="/cdn/weights")

    assert run(manifest) == "installed"

    assert_published(models, manifest, FILES)


# Download failures never publish and never damage a valid installation.


@pytest.fixture
def existing(server, run, models):
    """A valid installation at REVISION, then a server for OTHER_REVISION."""
    manifest = serve(server)
    run(manifest)
    version = current_version(models, manifest.id)
    server.requests.clear()
    return manifest, version


def assert_existing_intact(models, existing):
    manifest, version = existing
    assert current_version(models, manifest.id) == version
    assert_published(models, manifest, FILES)
    assert leftovers(models) == []
    assert sorted(p.name for p in version.parent.iterdir()) == [
        "current",
        version.name,
    ]


def test_hash_mismatch_fails_and_keeps_the_existing_install(
    server, run, models, existing
):
    bad = {"model.safetensors": WEIGHTS[:-1] + b"!"}
    manifest = serve(server, {**FILES, **bad}, revision=OTHER_REVISION)
    manifest = manifest.model_copy(
        update={
            "files": tuple(
                f.model_copy(update={"sha256": sha256(WEIGHTS)})
                if f.path == "model.safetensors"
                else f
                for f in manifest.files
            )
        }
    )

    error = failure(run, manifest)

    assert (error.code, error.file) == ("download_hash_mismatch", "model.safetensors")
    assert_existing_intact(models, existing)


def test_a_short_download_fails(server, run, models, existing):
    manifest = serve(server, revision=OTHER_REVISION)
    route = server.routes[f"/test/model/resolve/{OTHER_REVISION}/model.safetensors"]
    route.content_length = len(WEIGHTS) - 10
    route.truncate = len(WEIGHTS) - 10

    error = failure(run, manifest)

    assert (error.code, error.file) == ("download_size_mismatch", "model.safetensors")
    assert_existing_intact(models, existing)


def test_a_connection_dropped_mid_body_fails(server, run, models, existing):
    manifest = serve(server, revision=OTHER_REVISION)
    route = server.routes[f"/test/model/resolve/{OTHER_REVISION}/model.safetensors"]
    route.truncate = 100  # Content-Length still promises the whole file.

    error = failure(run, manifest)

    assert (error.code, error.file) == ("download_failed", "model.safetensors")
    assert_existing_intact(models, existing)


def test_an_oversized_download_is_refused(server, run, models, existing):
    manifest = serve(server, revision=OTHER_REVISION)
    route = server.routes[f"/test/model/resolve/{OTHER_REVISION}/config.json"]
    route.body = CONFIG + b" " * 1000
    route.content_length = None

    error = failure(run, manifest)

    assert (error.code, error.file) == ("download_size_mismatch", "config.json")
    assert_existing_intact(models, existing)


def test_an_undeclared_oversize_stops_at_the_manifest_size(
    server, run, models, existing
):
    manifest = serve(server, revision=OTHER_REVISION)
    route = server.routes[f"/test/model/resolve/{OTHER_REVISION}/model.safetensors"]
    route.body = WEIGHTS + b"x" * (4 << 20)
    route.content_length = -1

    error = failure(run, manifest)

    assert (error.code, error.file) == ("download_size_mismatch", "model.safetensors")
    assert_existing_intact(models, existing)


def test_http_errors_fail(server, run, models, existing):
    manifest = serve(server, revision=OTHER_REVISION)
    route = server.routes[f"/test/model/resolve/{OTHER_REVISION}/config.json"]
    route.status = 404

    error = failure(run, manifest)

    assert (error.code, error.file) == ("download_failed", "config.json")
    assert_existing_intact(models, existing)


def test_a_redirect_to_another_host_is_refused(server, run, models, existing):
    manifest = serve(server, revision=OTHER_REVISION)
    path = f"/test/model/resolve/{OTHER_REVISION}/model.safetensors"
    port = server.base.rsplit(":", 1)[1]
    server.routes[path] = Route(
        status=302, location=f"http://localhost:{port}/elsewhere"
    )

    error = failure(run, manifest)

    assert (error.code, error.file) == (
        "download_redirect_refused",
        "model.safetensors",
    )
    assert "/elsewhere" not in server.requests
    assert_existing_intact(models, existing)


def test_redirect_chains_are_bounded(server, run, models, existing):
    manifest = serve(server, revision=OTHER_REVISION)
    path = f"/test/model/resolve/{OTHER_REVISION}/config.json"
    server.routes[path] = Route(status=302, location=path)

    error = failure(run, manifest)

    assert (error.code, error.file) == ("download_redirect_refused", "config.json")
    assert server.requests.count(path) == 6
    assert_existing_intact(models, existing)


def test_a_manifest_url_off_the_allowlist_is_never_requested(
    server, run, models, existing
):
    manifest = serve(server, revision=OTHER_REVISION)

    error = failure(run, manifest, allow=lambda url: False)

    assert error.code == "download_origin_refused"
    assert server.requests == []
    assert_existing_intact(models, existing)


def test_an_interrupted_install_keeps_the_existing_one(server, run, models, existing):
    manifest = serve(server, revision=OTHER_REVISION)

    def interrupt(event, name):
        if event == "download" and name == "model.safetensors":
            raise KeyboardInterrupt

    with pytest.raises(KeyboardInterrupt):
        run(manifest, progress=interrupt)

    assert_existing_intact(models, existing)
    # The lock was released: the next install proceeds.
    assert run(manifest) == "installed"
    assert_published(models, manifest, FILES)


def test_a_killed_install_leaves_the_existing_one_and_is_cleaned_up(
    server, run, models, existing, tmp_path
):
    manifest = serve(server, revision=OTHER_REVISION)
    route = server.routes[f"/test/model/resolve/{OTHER_REVISION}/model.safetensors"]
    route.hold, route.hold_after = threading.Event(), 100
    manifest_file = tmp_path / "manifest.json"
    manifest_file.write_text(manifest.model_dump_json())
    script = (
        "import sys, httpx, pathlib\n"
        "from hagig.installer import install\n"
        "from hagig.manifest import Manifest\n"
        "m = Manifest.model_validate_json(pathlib.Path(sys.argv[1]).read_bytes())\n"
        "m = m.model_copy(update={'digest': sys.argv[3]})\n"
        "install(m, pathlib.Path(sys.argv[2]), client=httpx.Client(trust_env=False),\n"
        "        env={}, apple_silicon=True, allow=lambda url: True)\n"
    )
    child = subprocess.Popen(
        [sys.executable, "-c", script, str(manifest_file), str(models), manifest.digest]
    )
    try:
        assert route.started.wait(10)
        time.sleep(0.2)
        assert [p.name for p in models.glob(".staging-*")] != []
        os.kill(child.pid, signal.SIGKILL)
    finally:
        child.wait()
        route.hold.set()

    manifest_old, version = existing
    assert current_version(models, manifest_old.id) == version
    assert_published(models, manifest_old, FILES)

    route.hold = None
    assert run(manifest) == "installed"
    assert_published(models, manifest, FILES)
    assert leftovers(models) == []


def test_concurrent_installs_do_not_interleave(server, run, models):
    manifest = serve(server)
    route = server.routes[f"/test/model/resolve/{REVISION}/model.safetensors"]
    route.hold, route.hold_after = threading.Event(), 100
    results: list[object] = []
    first = threading.Thread(target=lambda: results.append(run(manifest)))
    first.start()
    try:
        assert route.started.wait(10)

        error = failure(run, manifest)

        assert error.code == "install_in_progress"
        assert [p.name for p in models.glob(".staging-*")] != []
    finally:
        route.hold.set()
        first.join(10)
    assert results == ["installed"]
    assert_published(models, manifest, FILES)
    assert leftovers(models) == []
    assert (models / LOCK_NAME).is_file()


def test_an_unsafe_lock_file_is_refused(server, run, models):
    manifest = serve(server)
    models.mkdir(parents=True)
    (models / "elsewhere").write_text("")
    os.symlink("elsewhere", models / LOCK_NAME)

    error = failure(run, manifest)

    assert error.code == "lock_file_unsafe"
    assert server.requests == []


def test_a_model_directory_that_is_not_a_directory_is_refused(server, run, models):
    manifest = serve(server)
    models.mkdir(parents=True)
    (models / manifest.id).write_text("")

    error = failure(run, manifest)

    assert error.code == "model_dir_unsafe"
    assert server.requests == []


# MLX conversion (a synthetic converter stands in for convert.py on Linux).


def converted(files=FILES):
    return {
        "config.json": files["config.json"],
        "weights.safetensors": b"float16" + files["model.safetensors"],
    }


def test_conversion_publishes_only_the_converted_files_with_their_hashes(
    server, run, models
):
    manifest = serve(server, converter=CONVERTER)

    assert run(manifest) == "installed"

    version = assert_published(models, manifest, converted())
    assert sorted(p.name for p in version.iterdir()) == [
        "config.json",
        "hagig-install.json",
        "weights.safetensors",
    ]
    record = (version / "hagig-install.json").read_text()
    assert sha256(b"float16" + WEIGHTS) in record
    assert sha256(WEIGHTS) not in record
    assert "/tools/convert.py" in server.requests


def test_converted_files_are_verified_at_load(server, run, models):
    manifest = serve(server, converter=CONVERTER)
    run(manifest)
    version = installed_model(models, manifest)
    weights = version / "weights.safetensors"
    data = weights.read_bytes()
    weights.write_bytes(data[:-1] + bytes([data[-1] ^ 1]))

    # Same size: the cheap check passes, the load-time hash does not.
    assert installed_model(models, manifest) == version
    with pytest.raises(ModelError) as caught:
        verify_installation(version)
    assert caught.value.code == "model_invalid"


def test_a_tampered_converter_is_never_run(server, run, models, tmp_path):
    marker = tmp_path / "ran"
    evil = CONVERTER + f"\nopen({str(marker)!r}, 'w')\n".encode()
    manifest = serve(server, converter=CONVERTER)
    server.routes["/tools/convert.py"] = Route(body=evil)
    assert manifest.conversion is not None
    manifest = manifest.model_copy(
        update={
            "conversion": manifest.conversion.model_copy(update={"size": len(evil)})
        }
    )

    error = failure(run, manifest)

    assert (error.code, error.file) == ("download_hash_mismatch", "convert.py")
    assert not marker.exists()
    assert current_version(models, manifest.id) is None
    assert leftovers(models) == []


@pytest.mark.parametrize(
    ("config", "code"),
    [
        (b'{"mode": "fail"}', "conversion_failed"),
        (b'{"mode": "extra"}', "conversion_output_invalid"),
    ],
)
def test_conversion_failures_keep_the_existing_install(
    server, run, models, config, code
):
    good = serve(server, converter=CONVERTER)
    run(good)
    before = current_version(models, good.id)
    bad = serve(
        server, {**FILES, "config.json": config}, converter=CONVERTER, revision="d" * 40
    )

    error = failure(run, bad)

    assert error.code == code
    assert current_version(models, good.id) == before
    assert_published(models, good, converted())
    assert leftovers(models) == []


def test_conversion_models_are_refused_off_apple_silicon(server, run, models):
    manifest = serve(server, converter=CONVERTER)

    error = failure(run, manifest, apple_silicon=False)

    assert error.code == "model_unsupported_on_platform"
    assert server.requests == []
    assert not models.exists()
