"""Shared pytest fixtures.

We mock APIM with respx so the test suite runs entirely offline.
"""

from __future__ import annotations

import os
import sys
import threading
from pathlib import Path
from types import SimpleNamespace

import pytest
import respx
from azure.core import MatchConditions
from azure.core.exceptions import ResourceExistsError, ResourceModifiedError

# Make `function_app` importable.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

# Configure env BEFORE function_app is imported anywhere.
os.environ.setdefault("APIM_GATEWAY_URL", "https://apim-test.azure-api.net")
os.environ.setdefault("CONTENT_SAFETY_API_VERSION", "2024-09-01")
os.environ.setdefault("CONTENT_SAFETY_PREVIEW_API_VERSION", "2024-09-15-preview")


class MemoryContainer:
    """Models Azure's atomic conditional writes across independent store clients."""

    def __init__(self):
        self.records = {}
        self.lock = threading.Lock()
        self.version = 0
        self.before_replace = None
        self.fail_write = False

    def get_blob_client(self, name):
        container = self

        class Blob:
            def upload_blob(self, data, overwrite=False, etag=None, match_condition=None):
                if overwrite and container.before_replace:
                    container.before_replace()
                with container.lock:
                    if container.fail_write:
                        raise OSError("storage unavailable")
                    if not overwrite and name in container.records:
                        raise ResourceExistsError("already exists")
                    if overwrite:
                        assert match_condition == MatchConditions.IfNotModified
                        if container.records[name][1] != etag:
                            raise ResourceModifiedError("ETag mismatch")
                    container.version += 1
                    version = str(container.version)
                    container.records[name] = (data, version)
                    return {"etag": version}

            def download_blob(self):
                with container.lock:
                    data, etag = container.records[name]
                return SimpleNamespace(
                    readall=lambda: data, properties=SimpleNamespace(etag=etag),
                )

        return Blob()


@pytest.fixture
def durable_store(monkeypatch):
    import function_app
    from idempotency import BlobStore

    store = BlobStore(MemoryContainer(), ttl=60)
    monkeypatch.setattr(function_app, "_idempotency_store", lambda: store)
    return store


@pytest.fixture(autouse=True)
def offline_coordination(durable_store):
    """No test should attempt managed identity discovery or Azure network access."""


@pytest.fixture
def apim_mock():
    """Yield a respx mock router scoped to the APIM gateway base URL."""
    with respx.mock(
        base_url="https://apim-test.azure-api.net",
        assert_all_called=False,
    ) as mock:
        yield mock
