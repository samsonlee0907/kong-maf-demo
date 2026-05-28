"""
Validate the Azure Kong -> Foundry Hosted Agent path.

This smoke test is intentionally lightweight: it confirms gateway health and
then sends one non-streaming Responses API call through Azure Kong.
"""

from __future__ import annotations

import json
import os
from pathlib import Path

import requests
from dotenv import load_dotenv

ENV_FILE = Path(__file__).resolve().parents[1] / "agent" / ".env"
if ENV_FILE.exists():
    load_dotenv(ENV_FILE)

GATEWAY_URL = (
    os.getenv("AZURE_KONG_GATEWAY_URL")
    or os.getenv("KONG_URL")
    or ""
).rstrip("/")


def extract_text(payload: dict) -> str:
    output = payload.get("output", [])
    chunks: list[str] = []
    for item in output:
        if item.get("type") != "message":
            continue
        for content in item.get("content", []):
            text = content.get("text")
            if text:
                chunks.append(text)
    return "".join(chunks).strip()


def test_cloud_gateway() -> None:
    if not GATEWAY_URL:
        raise RuntimeError(
            "AZURE_KONG_GATEWAY_URL is not configured. Deploy Azure Kong first or set KONG_URL."
        )

    print("=" * 60)
    print("  TEST: Azure Kong -> Foundry Hosted Agent")
    print("=" * 60)
    print(f"Gateway URL: {GATEWAY_URL}")

    health = requests.get(f"{GATEWAY_URL}/health", timeout=30)
    print(f"\nHealth status: {health.status_code}")
    print(health.text)
    health.raise_for_status()
    health_payload = health.json()
    assert health_payload.get("gateway") == "kong-azure"

    response = requests.post(
        f"{GATEWAY_URL}/responses",
        json={
            "input": "Reply with READY only.",
            "stream": False,
        },
        headers={
            "Content-Type": "application/json",
            "X-Trace-Id": "cloud-gateway-smoke",
        },
        timeout=120,
    )

    print(f"\nResponses status: {response.status_code}")
    print(f"Content-Type: {response.headers.get('Content-Type')}")
    response.raise_for_status()

    payload = response.json()
    text = extract_text(payload)
    assert text, "Hosted Agent response text should not be empty."

    summary = {
        "gateway": GATEWAY_URL,
        "agent": health_payload.get("agent"),
        "response_id": payload.get("id"),
        "assistant_text": text,
    }
    print(json.dumps(summary, indent=2))
    print("\nCloud gateway test PASSED")


if __name__ == "__main__":
    test_cloud_gateway()
