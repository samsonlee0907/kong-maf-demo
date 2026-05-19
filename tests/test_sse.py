"""
Test the streaming path through Kong.
"""

from __future__ import annotations

import json
import os
import time

import requests

KONG_URL = os.getenv("KONG_URL", "http://localhost:8000").rstrip("/")


def test_sse():
    print("=" * 60)
    print("  TEST: SSE (Streaming) via Kong")
    print("=" * 60)

    payload = {
        "message": "Explain the difference between SSE and WebSockets in 3 sentences."
    }

    start = time.time()
    first_token_time = None
    token_count = 0
    full_response = []

    response = requests.post(
        f"{KONG_URL}/stream",
        json=payload,
        headers={
            "Content-Type": "application/json",
            "Accept": "text/event-stream",
        },
        stream=True,
        timeout=120,
    )

    print(f"\nStatus Code: {response.status_code}")
    print(f"Content-Type: {response.headers.get('Content-Type')}")
    print("\nStreaming tokens:\n")

    for line in response.iter_lines(decode_unicode=True):
        if not line:
            continue

        if not line.startswith("data:"):
            continue

        payload_text = line[len("data:") :].strip()
        data = json.loads(payload_text)

        if "chunk" in data:
            if first_token_time is None:
                first_token_time = time.time() - start
            token_count += 1
            full_response.append(data["chunk"])
            print(data["chunk"], end="", flush=True)
        elif data.get("status") == "complete":
            print("\n\n--- Stream Complete ---")
            print(f"Total tokens received: {data.get('total_tokens', token_count)}")

    elapsed = time.time() - start

    print(f"\n{'=' * 40}")
    print(
        f"Time to first token: {first_token_time:.3f}s"
        if first_token_time is not None
        else "No tokens received"
    )
    print(f"Total streaming time: {elapsed:.2f}s")
    print(f"Tokens received: {token_count}")
    print(f"Full response length: {len(''.join(full_response))} chars")

    response.raise_for_status()
    assert token_count > 0
    assert first_token_time is not None

    print("\nSSE test PASSED")
    return elapsed, first_token_time


if __name__ == "__main__":
    test_sse()
