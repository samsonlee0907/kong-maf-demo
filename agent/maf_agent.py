"""
Microsoft Agent Framework agent definition for the Kong demo.
"""

from __future__ import annotations

import os
from typing import Iterable

from dotenv import load_dotenv

from agent_framework import Agent
from agent_framework.foundry import FoundryChatClient
from azure.identity import DefaultAzureCredential

load_dotenv()

REQUIRED_ENV_VARS: tuple[str, ...] = (
    "FOUNDRY_PROJECT_ENDPOINT",
)


def validate_environment(required: Iterable[str] = REQUIRED_ENV_VARS) -> None:
    missing = [name for name in required if not os.getenv(name)]
    if missing:
        missing_list = ", ".join(sorted(missing))
        raise RuntimeError(f"Missing required environment variables: {missing_list}")


def create_agent() -> Agent:
    validate_environment()

    model_name = (
        os.getenv("AZURE_AI_MODEL_DEPLOYMENT_NAME")
        or os.getenv("FOUNDRY_MODEL")
        or os.getenv("FOUNDRY_MODEL_DEPLOYMENT_NAME")
    )
    if not model_name:
        raise RuntimeError(
            "Missing required environment variables: AZURE_AI_MODEL_DEPLOYMENT_NAME or FOUNDRY_MODEL"
        )

    client = FoundryChatClient(
        project_endpoint=os.environ["FOUNDRY_PROJECT_ENDPOINT"],
        credential=DefaultAzureCredential(),
        model=model_name,
        allow_preview=True,
    )

    return Agent(
        name="kong_maf_demo_agent",
        instructions=(
            "You are a helpful AI assistant for the Kong plus Microsoft Agent Framework demo. "
            "Answer clearly and briefly. "
            "If asked who you are, explain that you are a Microsoft Agent Framework agent "
            "served through Kong Gateway and backed by a Microsoft Foundry project."
        ),
        client=client,
    )
