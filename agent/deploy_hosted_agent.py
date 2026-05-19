"""
Create or update a Hosted Agent version in Microsoft Foundry for this demo.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time

from azure.ai.projects import AIProjectClient
from azure.ai.projects.models import AgentProtocol, HostedAgentDefinition, ProtocolVersionRecord
from azure.identity import DefaultAzureCredential
from dotenv import load_dotenv

load_dotenv()

POLL_INTERVAL_SECONDS = 10
DEFAULT_TIMEOUT_SECONDS = 900


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Deploy the Kong + MAF Hosted Agent to Foundry.")
    parser.add_argument("--agent-name", default="kong-maf-hosted-agent")
    parser.add_argument("--image", required=True)
    parser.add_argument("--cpu", default="0.5")
    parser.add_argument("--memory", default="1Gi")
    parser.add_argument("--protocol-version", default="1.0.0")
    parser.add_argument("--timeout-seconds", type=int, default=DEFAULT_TIMEOUT_SECONDS)
    parser.add_argument(
        "--model-deployment",
        default=(
            os.getenv("FOUNDRY_MODEL_DEPLOYMENT_NAME")
            or os.getenv("FOUNDRY_MODEL")
            or os.getenv("AZURE_AI_MODEL_DEPLOYMENT_NAME")
        ),
    )
    return parser


def require_env(name: str) -> str:
    value = os.getenv(name)
    if not value:
        raise RuntimeError(f"Missing required environment variable: {name}")
    return value


def create_client() -> AIProjectClient:
    endpoint = require_env("FOUNDRY_PROJECT_ENDPOINT")
    return AIProjectClient(endpoint=endpoint, credential=DefaultAzureCredential(), allow_preview=True)


def wait_for_active_version(project: AIProjectClient, agent_name: str, version: str, timeout: int):
    deadline = time.time() + timeout
    while time.time() < deadline:
        details = project.agents.get_version(agent_name=agent_name, agent_version=version)
        status = str(getattr(details, "status", "unknown")).lower()
        print(f"[poll] version={version} status={status}")
        if status in {"active", "succeeded"}:
            return details
        if status in {"failed", "error"}:
            raise RuntimeError(f"Hosted agent version {version} failed with status: {status}")
        time.sleep(POLL_INTERVAL_SECONDS)
    raise TimeoutError(f"Timed out waiting for hosted agent version {version} to become active.")


def try_invoke(project: AIProjectClient, agent_name: str) -> str:
    client = project.get_openai_client(agent_name=agent_name)
    request = {
        "input": "Reply with the exact text READY.",
        "stream": False,
    }

    response = client.responses.create(**request)

    output_text = getattr(response, "output_text", None)
    if output_text:
        return output_text

    output = getattr(response, "output", None)
    if isinstance(output, list):
        parts: list[str] = []
        for item in output:
            content = getattr(item, "content", None) or item.get("content", [])
            for chunk in content:
                text = getattr(chunk, "text", None)
                if text:
                    parts.append(text)
                elif isinstance(chunk, dict) and chunk.get("text"):
                    parts.append(chunk["text"])
        if parts:
            return "".join(parts)

    return json.dumps(response.to_dict(), indent=2)


def main() -> int:
    args = build_parser().parse_args()

    if not args.model_deployment:
        raise RuntimeError(
            "Missing model deployment name. Set FOUNDRY_MODEL_DEPLOYMENT_NAME or pass --model-deployment."
        )

    project = create_client()

    definition = HostedAgentDefinition(
        kind="hosted",
        image=args.image,
        cpu=args.cpu,
        memory=args.memory,
        container_protocol_versions=[
            ProtocolVersionRecord(protocol=AgentProtocol.RESPONSES, version=args.protocol_version)
        ],
        environment_variables={
            "AZURE_AI_MODEL_DEPLOYMENT_NAME": args.model_deployment,
        },
    )

    print(f"[deploy] creating or updating hosted agent '{args.agent_name}' from image {args.image}")
    version = project.agents.create_version(
        agent_name=args.agent_name,
        definition=definition,
        description="Kong + MAF demo hosted agent",
        metadata={
            "source": "codex-demo",
            "protocol": "responses",
        },
    )

    version_id = str(getattr(version, "version", ""))
    print(f"[deploy] submitted version {version_id}")
    active = wait_for_active_version(project, args.agent_name, version_id, args.timeout_seconds)

    print("[deploy] hosted agent version is active")
    print(json.dumps(active.as_dict(), indent=2, default=str))

    try:
        agent_details = project.agents.get(args.agent_name)
        print("[deploy] hosted agent details:")
        print(json.dumps(agent_details.as_dict(), indent=2, default=str))

        result = try_invoke(project, args.agent_name)
        print("[invoke] hosted agent smoke test response:")
        print(result)
    except Exception as exc:
        print(f"[invoke] smoke test failed: {exc}", file=sys.stderr)
        return 2

    return 0


if __name__ == "__main__":
    sys.exit(main())
