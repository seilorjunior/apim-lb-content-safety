"""Durable, fail-closed coordination; records must never have a blob lifecycle TTL.

Only completed, definitive responses may be reclaimed after the replay window.
Pending/uncertain records require operator reconciliation with the backend before
deletion: a worker may have died after sending a mutation but before saving it.
"""

import base64
import hashlib
import json
import time
from dataclasses import dataclass

from azure.core import MatchConditions
from azure.core.exceptions import ResourceExistsError, ResourceModifiedError


def digest(value):
    return hashlib.sha256(
        json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()


@dataclass(frozen=True)
class Envelope:
    status: int
    body: bytes
    headers: dict

    def serialize(self):
        return {
            "status": self.status,
            "body": base64.b64encode(self.body).decode("ascii"),
            "headers": self.headers,
        }

    @classmethod
    def deserialize(cls, value):
        return cls(
            status=value["status"],
            body=base64.b64decode(value["body"], validate=True),
            headers=value["headers"],
        )


@dataclass(frozen=True)
class Claim:
    name: str
    etag: str
    fingerprint: str

    def __post_init__(self):
        if not self.etag:
            raise ValueError("Storage did not acknowledge conditional ownership")


class InProgress(Exception):
    pass


class FingerprintConflict(Exception):
    pass


class BlobStore:
    """All writes are atomic and conditional; no lease or timeout grants ownership."""

    def __init__(self, container, ttl, clock=time.time):
        if ttl < 60 or ttl > 604800:
            raise ValueError("Idempotency TTL must be between 60 and 604800 seconds")
        self.container = container
        self.ttl = ttl
        self.clock = clock

    def claim(self, scope, key, fingerprint):
        name = f"v1/{digest([scope, key])}.json"
        blob = self.container.get_blob_client(name)
        pending = json.dumps({
            "version": 1,
            "state": "pending",
            "fingerprint": fingerprint,
            "created_at": self.clock(),
        }).encode()
        try:
            result = blob.upload_blob(pending, overwrite=False)
            return Claim(name, result["etag"], fingerprint)
        except (ResourceExistsError, ResourceModifiedError):
            pass

        download = blob.download_blob()
        record = json.loads(download.readall())
        if record["version"] != 1:
            raise ValueError("Unsupported idempotency record")
        if record["state"] == "completed" and record["expires_at"] <= self.clock():
            # A concurrent caller may have reclaimed this record since our read.
            # Only the winner of this compare-and-swap may send the mutation.
            try:
                result = blob.upload_blob(
                    pending, overwrite=True, etag=download.properties.etag,
                    match_condition=MatchConditions.IfNotModified,
                )
            except (ResourceExistsError, ResourceModifiedError) as exc:
                raise InProgress from exc
            return Claim(name, result["etag"], fingerprint)
        if record["fingerprint"] != fingerprint:
            raise FingerprintConflict
        if record["state"] == "pending":
            raise InProgress
        if record["state"] not in {"completed", "uncertain"}:
            raise ValueError("Invalid idempotency state")
        return Envelope.deserialize(record["response"])

    def complete(self, claim, response, definitive=True):
        record = {
            "version": 1,
            "state": "completed" if definitive else "uncertain",
            "fingerprint": claim.fingerprint,
            "response": response.serialize(),
        }
        if definitive:
            record["expires_at"] = self.clock() + self.ttl
        self.container.get_blob_client(claim.name).upload_blob(
            json.dumps(record).encode(), overwrite=True, etag=claim.etag,
            match_condition=MatchConditions.IfNotModified,
        )
