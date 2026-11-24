"""API tests run against the ISOLATED test database (synthetic fixtures), never the main one.
scripts/run_api_tests.sh rebuilds equityiq_test, loads fixtures and runs the pipeline first."""
import os

os.environ["EQUITYIQ_API_DATABASE"] = "test"   # must be set before the app/pool is imported

import pytest  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

from backend.main import app  # noqa: E402


@pytest.fixture(scope="session")
def client():
    with TestClient(app, raise_server_exceptions=False) as c:
        yield c
