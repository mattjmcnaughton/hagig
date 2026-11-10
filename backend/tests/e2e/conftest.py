import pytest

from tests.support.harness import Home, short_runtime_base


@pytest.fixture
def home(tmp_path):
    with short_runtime_base() as runtime_base:
        user = Home(tmp_path, runtime_base)
        try:
            yield user
        finally:
            user.cleanup()


@pytest.fixture
def server(home):
    """A running test server with the fake engine and an installed model."""
    home.write_config()
    home.install_model()
    home.start_server()
    return home
