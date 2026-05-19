"""
Test the synchronous path through Kong.
"""

from __future__ import annotations

import json
import os
import time

import requests

KONG_URL = os.getenv("KONG_URL", "http://localhost:8000").rstrip("/")


def test_non_sse() -> float:
    print("=" * 60)
    print("  TEST: Non-SSE (Synchronous REST) via Kong")
    print("=" * 60)

    payload = {
        "message": "List 3 benefits of using an API gateway for AI agents."
    }

    start = time.time()
    response = requests.post(
        f"{KONG_URL}/invoke",
        json=payload,
        headers={"Content-Type": "application/json"},
        timeout=120,
    )
    elapsed = time.time() - start

    print(f"\nStatus Code: {response.status_code}")
    print(f"Content-Type: {response.headers.get('Content-Type')}")
    print(f"Total Time: {elapsed:.2f}s")
    print("\nResponse:")
    print(json.dumps(response.json(), indent=2))

    response.raise_for_status()
    data = response.json()
    assert data["mode"] == "non-sse"
    assert data["output"]

    print("\nNon-SSE test PASSED")
    return elapsed


if __name__ == "__main__":
    test_non_sse()
