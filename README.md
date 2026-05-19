# Kong + Microsoft Agent Framework Demo

This repository demonstrates how to place a Microsoft Agent Framework (MAF) agent behind Kong Gateway and run the same agent in two useful modes:

- a local FastAPI host for detailed tracing and quick iteration
- a Foundry Hosted Agent behind Kong on Azure for a cloud-native gateway path

The project is opinionated around one question: how should an AI gateway behave when agent traffic is sometimes synchronous and sometimes streamed? Kong gives the demo a stable front door, while MAF provides the agent abstraction that survives the move from local development to Foundry hosting.

## Why Kong

Kong is widely used because it gives teams one place to handle API concerns that otherwise leak into every application:

- routing and stable client-facing URLs
- auth and header transformation
- CORS, timeouts, retries, and buffering policy
- observability and policy enforcement

That matters for agent systems because agent traffic is not just ordinary JSON RPC. Some requests are long-running, some need streaming, and some need upstream identity injection. In this repo, Kong is not decorative. It actively controls:

- local routing to `/invoke`, `/stream`, `/health`, `/portal`, and `/ui/*`
- Azure routing to the Hosted Agent `POST /responses` endpoint
- browser CORS behavior
- streaming pass-through behavior
- bearer token injection from managed identity in Azure Container Apps

For readers who want to go deeper into Kong itself, start with the public repository and product docs:

- [Kong Gateway source repository](https://github.com/Kong/kong)
- [Kong Gateway documentation](https://developer.konghq.com/gateway/)

## Why MAF

Microsoft Agent Framework is the orchestration layer in this project. Instead of treating the demo as a thin wrapper around one model call, MAF gives the codebase a place to express agent behavior, runtime boundaries, and future multi-step coordination.

MAF is useful here because it does more than define a prompt:

- it gives the project a first-class `Agent` abstraction instead of coupling behavior to individual HTTP handlers
- it provides model clients that can target Foundry while preserving a consistent programming model
- it supports agent sessions and conversation state, which matters once a demo grows into multi-turn behavior
- it provides middleware and extension points, which is where logging, safety policy, interception, and tool controls belong
- it supports MCP and tool integration patterns, so the same project can expand from pure chat into actionable agents
- it includes workflow-oriented building blocks for multi-step and multi-agent orchestration rather than forcing everything into one request handler

That is the real value in this repository: Kong owns the gateway edge, while MAF owns the agent runtime model. Kong decides how requests enter, route, stream, and authenticate. MAF decides how the agent is defined, hosted, and extended.

The local FastAPI host and the Foundry Hosted Agent are two different runtimes for the same agent definition, not two unrelated agents. That reuse is what keeps the local trace demo and the Azure Hosted Agent deployment aligned.

For readers who want the upstream implementation details, start with:

- [Microsoft Agent Framework repository](https://github.com/microsoft/agent-framework)
- [Microsoft Agent Framework documentation](https://learn.microsoft.com/en-us/agent-framework/)

## What This Repo Shows

- non-streaming requests through Kong to a MAF-backed agent
- streaming requests through Kong to a MAF-backed agent
- a browser portal that visualizes the request path
- a Foundry Hosted Agent running the same agent logic in Azure
- Kong running both locally and on Azure

## Architecture

### Local development path

```text
Browser or test client
  -> Kong Gateway (Docker, DB-less)
  -> FastAPI host
  -> MAF agent
  -> Foundry project endpoint
```

### Azure hosted path

```text
Browser portal
  -> Kong Gateway (Azure Container Apps)
  -> Foundry Hosted Agent
  -> MAF agent container
  -> Foundry model runtime
```

## Streaming and Non-Streaming

### Non-streaming

Local mode uses `POST /invoke` and returns one JSON payload after the MAF agent completes.

Azure mode uses `POST /responses` with `"stream": false` and returns one complete Responses API object after the Hosted Agent finishes.

### Streaming

Local mode uses `POST /stream` and returns server-sent events from the FastAPI host.

Azure mode uses `POST /responses` with `"stream": true` and forwards Hosted Agent Responses API SSE events through Kong.

The two important gateway behaviors are:

- non-streaming requests can be handled as ordinary HTTP proxy traffic
- streaming requests need buffering behavior that preserves incremental delivery

## Repository Layout

```text
.
|-- agent/
|   |-- .env.example
|   |-- agent.yaml
|   |-- demo_portal.html
|   |-- deploy_hosted_agent.py
|   |-- hosted_main.py
|   |-- maf_agent.py
|   |-- requirements.txt
|   +-- server.py
|-- infra/
|   |-- azuredeploy.json
|   |-- azuredeploy.parameters.example.json
|   |-- deploy_azure_demo.ps1
|   |-- deploy_hosted_agent.ps1
|   |-- deploy_kong_azure.ps1
|   |-- foundry-account-project.bicep
|   +-- provision.ps1
|-- kong/
|   |-- azure.Dockerfile
|   |-- docker-compose.yml
|   |-- kong.azure.template.yaml
|   |-- kong.yaml
|   +-- start-kong.sh
|-- tests/
|   |-- test_both.ps1
|   |-- test_both.sh
|   |-- test_non_sse.py
|   |-- test_project_endpoint.py
|   +-- test_sse.py
|-- cleanup.ps1
|-- cleanup.sh
+-- README.md
```

## Prerequisites

- Python 3.10+
- Azure CLI authenticated to a subscription with Azure AI Foundry access
- Docker Desktop if you want the local Kong path
- permission to deploy `gpt-5.4-mini`

Install checks:

```powershell
python --version
az version
az account show
docker --version
docker compose version
```

## Deploy to Azure

The repository includes an ARM template for the Foundry bootstrap resources at [infra/azuredeploy.json](infra/azuredeploy.json).

After you publish this repository to GitHub, replace both `YOUR_GITHUB_OWNER` and `YOUR_GITHUB_REPO` in the button below. The button will provision:

- the Azure AI Foundry account
- the Foundry project
- the `gpt-5.4-mini` model deployment

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FYOUR_GITHUB_OWNER%2FYOUR_GITHUB_REPO%2Fmain%2Finfra%2Fazuredeploy.json)

The button intentionally bootstraps only the base Foundry resources. The Hosted Agent and Azure Kong deployment still require container image builds, so they are handled by the scripts in `infra/`.

### Parameter file

An example parameters file is included at [infra/azuredeploy.parameters.example.json](infra/azuredeploy.parameters.example.json).

## Provision from PowerShell

If you prefer CLI-driven setup instead of the portal button:

```powershell
Set-Location .\infra
.\provision.ps1
```

That script provisions the Foundry account, project, and model deployment, then writes `agent/.env`.

## Run the Local Portal

If you already ran `infra/provision.ps1`, keep the generated `agent/.env`. Otherwise copy `agent/.env.example` to `agent/.env` and fill in the Foundry values manually.

```powershell
Set-Location .\agent
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
Copy-Item .env.example .env
python .\server.py
```

If port `8080` is already in use:

```powershell
$env:AGENT_PORT="8088"
python .\server.py
```

Open the portal:

- [http://127.0.0.1:8080/portal](http://127.0.0.1:8080/portal)

The portal switches behavior based on configuration:

- local mode uses `/invoke` and `/stream`
- Azure hosted mode uses `/responses`

## Run Local Kong

```powershell
Set-Location .\kong
docker compose up -d
```

Health check:

```powershell
curl.exe http://127.0.0.1:8000/health
```

## Deploy the Hosted Agent

```powershell
Set-Location .\infra
.\deploy_hosted_agent.ps1
```

This script:

- creates or reuses Azure Container Registry
- builds the Hosted Agent image
- publishes a Foundry Hosted Agent version
- grants Foundry access to the Hosted Agent identities

## Deploy Kong on Azure

```powershell
Set-Location .\infra
.\deploy_kong_azure.ps1
```

This script:

- builds the Kong Azure image in ACR
- deploys Kong to Azure Container Apps
- grants ACR pull access to the Container App identity
- grants Foundry access to the Container App identity
- writes the Azure Kong URL back into `agent/.env`

## One-Command Azure Demo Path

```powershell
Set-Location .\infra
.\deploy_azure_demo.ps1
```

That script runs the Hosted Agent deployment first and then deploys the Azure Kong gateway.

## Example Requests

### Local non-streaming

```powershell
curl.exe -X POST http://127.0.0.1:8000/invoke `
  -H "Content-Type: application/json" `
  -d "{\"message\":\"Explain the role of Kong in one sentence.\"}"
```

### Local streaming

```powershell
curl.exe -N -X POST http://127.0.0.1:8000/stream `
  -H "Content-Type: application/json" `
  -H "Accept: text/event-stream" `
  -d "{\"message\":\"Explain SSE in one short paragraph.\"}"
```

### Azure Hosted Agent non-streaming

```powershell
curl.exe -X POST https://YOUR_KONG_GATEWAY_FQDN/responses `
  -H "Content-Type: application/json" `
  -d "{\"input\":\"Reply with the exact text READY.\",\"stream\":false}"
```

### Azure Hosted Agent streaming

```powershell
curl.exe -N -X POST https://YOUR_KONG_GATEWAY_FQDN/responses `
  -H "Content-Type: application/json" `
  -H "Accept: text/event-stream" `
  -d "{\"input\":\"Count from one to three.\",\"stream\":true}"
```

## Test Scripts

The test scripts accept environment overrides so the repo is not tied to one machine layout.

PowerShell:

```powershell
$env:KONG_URL="http://localhost:8000"
$env:AGENT_URL="http://localhost:8080"
.\tests\test_both.ps1
```

Bash:

```bash
KONG_URL=http://localhost:8000 AGENT_URL=http://localhost:8080 ./tests/test_both.sh
```

## Important Files

- [agent/maf_agent.py](agent/maf_agent.py): shared MAF agent definition
- [agent/server.py](agent/server.py): local FastAPI portal host and trace surface
- [agent/hosted_main.py](agent/hosted_main.py): Foundry Hosted Agent entrypoint
- [kong/kong.yaml](kong/kong.yaml): local Kong DB-less configuration
- [kong/kong.azure.template.yaml](kong/kong.azure.template.yaml): Azure Kong config for the Hosted Agent path
- [infra/provision.ps1](infra/provision.ps1): base Foundry provisioning
- [infra/deploy_hosted_agent.ps1](infra/deploy_hosted_agent.ps1): Hosted Agent deployment
- [infra/deploy_kong_azure.ps1](infra/deploy_kong_azure.ps1): Azure Kong deployment

## Cleanup

PowerShell:

```powershell
.\cleanup.ps1
```

Bash:

```bash
./cleanup.sh
```
