"""
Foundry hosted-agent entrypoint for the Kong + MAF demo.

This wraps the same MAF agent used by the local FastAPI demo with the
Responses protocol host required by Foundry Hosted Agents.
"""

from __future__ import annotations

import logging
import os

from agent_framework_foundry_hosting import ResponsesHostServer
from dotenv import load_dotenv

from maf_agent import create_agent

load_dotenv(override=False)

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("kong-maf-hosted-agent")


def main() -> None:
    agent = create_agent()
    port = int(os.getenv("PORT", "8088"))
    logger.info("Starting Foundry hosted agent adapter on port %s", port)
    ResponsesHostServer(agent).run(port=port)


if __name__ == "__main__":
    main()
