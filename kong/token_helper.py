from __future__ import annotations

import os
import sys

from azure.identity import ManagedIdentityCredential


def main() -> int:
    scope = os.getenv("AZURE_AUTH_SCOPE", "https://ai.azure.com/.default")
    client_id = os.getenv("AZURE_CLIENT_ID") or None

    credential = ManagedIdentityCredential(client_id=client_id)
    token = credential.get_token(scope)
    sys.stdout.write(token.token)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
