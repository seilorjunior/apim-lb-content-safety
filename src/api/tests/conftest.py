"""Shared pytest fixtures.

We mock APIM with respx so the test suite runs entirely offline.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest
import respx

# Make `function_app` importable.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

# Configure env BEFORE function_app is imported anywhere.
os.environ.setdefault("APIM_GATEWAY_URL", "https://apim-test.azure-api.net")
os.environ.setdefault("CONTENT_SAFETY_API_VERSION", "2024-09-01")
os.environ.setdefault("CONTENT_SAFETY_PREVIEW_API_VERSION", "2024-09-15-preview")


@pytest.fixture
def apim_mock():
    """Yield a respx mock router scoped to the APIM gateway base URL."""
    with respx.mock(
        base_url="https://apim-test.azure-api.net",
        assert_all_called=False,
    ) as mock:
        yield mock
