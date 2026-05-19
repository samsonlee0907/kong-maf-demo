"""
Direct smoke test against the Foundry project endpoint.

This is intentionally separate from the Kong tests so we can validate the
project endpoint and GPT-5 request format before bringing up the local server.
"""

from __future__ import annotations

import os
from pathlib import Path

from azure.ai.projects import AIProjectClient
from azure.identity import AzureCliCredential
from dotenv import load_dotenv

ENV_FILE = Path(__file__).resolve().parents[1] / "agent" / ".env"
load_dotenv(ENV_FILE)


def test_project_endpoint() -> None:
    endpoint = os.environ["FOUNDRY_PROJECT_ENDPOINT"]
    deployment_name = os.environ["FOUNDRY_MODEL"]

    project = AIProjectClient(
        endpoint=endpoint,
        credential=AzureCliCredential(),
    )
    openai_client = project.get_openai_client()

    response = openai_client.chat.completions.create(
        model=deployment_name,
        messages=[
            {"role": "system", "content": "You are a concise assistant."},
            {"role": "user", "content": "In one sentence, confirm this is a Foundry project endpoint smoke test."},
        ],
        max_completion_tokens=128,
    )

    text = response.choices[0].message.content
    print(text)
    assert text


if __name__ == "__main__":
    test_project_endpoint()
