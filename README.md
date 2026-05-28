# Kong + Microsoft Agent Framework Demo

This repository demonstrates one agent in two deployment shapes:

- **Cloud Gateway mode**: `Browser -> Azure Kong -> Foundry Hosted Agent -> model runtime`
- **Local Preview mode**: `Browser -> local FastAPI adapter -> MAF agent -> Foundry project endpoint`

The point of the repo is not just "call a model through a gateway." It shows how a gateway and an agent runtime divide responsibilities when requests may be synchronous or streamed, local or cloud-hosted.

## Why Kong

Kong is popular because it gives teams one place to handle API concerns that would otherwise leak into every application:

- stable client-facing routes
- auth and header transformation
- CORS, timeouts, retries, and buffering policy
- observability and policy enforcement

That matters for agent systems because agent traffic is not just ordinary JSON. Some calls need streaming semantics, some need upstream identity injection, and some need a stable browser-facing edge even while the backend runtime changes.

In this repo, Kong is not decorative. It actively controls:

- local routing to `/invoke`, `/stream`, `/health`, `/portal`, and `/ui/*`
- Azure routing to the Hosted Agent `POST /responses` endpoint
- browser CORS behavior
- streaming pass-through behavior
- bearer-token injection from managed identity in Azure Container Apps

Upstream Kong references:

- [Kong Gateway source repository](https://github.com/Kong/kong)
- [Kong Gateway documentation](https://developer.konghq.com/gateway/)

## Why MAF

Microsoft Agent Framework (MAF) is the orchestration layer in this project. It keeps the agent logic stable while the hosting model changes.

MAF adds value here because it provides:

- a first-class `Agent` abstraction instead of burying behavior inside HTTP handlers
- model clients that target Foundry while keeping a consistent programming model
- session and conversation state support for multi-turn behavior
- middleware and extension points for logging, policy, interception, and tools
- MCP and tool-integration patterns for moving from chat to actionable agents
- workflow-oriented building blocks for multi-step or multi-agent orchestration

That separation is the architectural point of the demo:

- **Kong owns the edge**: routing, auth, headers, CORS, buffering, and gateway policy
- **MAF owns the agent runtime**: instructions, model client, tool use, streaming, and future orchestration

The local FastAPI host and the Azure Hosted Agent both reuse the same agent definition from `agent/maf_agent.py`. They are two runtimes for the same agent, not two different agents.

Upstream MAF references:

- [Microsoft Agent Framework repository](https://github.com/microsoft/agent-framework)
- [Microsoft Agent Framework documentation](https://learn.microsoft.com/en-us/agent-framework/)

## What This Repo Demonstrates

- non-streaming requests through Kong to a MAF-backed agent
- streaming requests through Kong to a MAF-backed agent
- a browser portal that visualizes the request path
- the same agent logic running as a Foundry Hosted Agent in Azure
- Kong running both locally and in Azure Container Apps

## Architecture

### Cloud Gateway mode

```text
Browser portal
  -> Azure Kong Gateway
  -> Foundry Hosted Agent
  -> MAF agent runtime
  -> Foundry model runtime
```

### Local Preview mode

```text
Browser or test client
  -> local FastAPI adapter
  -> MAF agent
  -> Foundry project endpoint
```

### Local Kong mode

```text
Browser or test client
  -> Kong Gateway (Docker, DB-less)
  -> local FastAPI adapter
  -> MAF agent
  -> Foundry project endpoint
```

## Routes and What They Demonstrate

### Local portal and adapter routes

These are served by `agent/server.py`.

`GET /portal`

- serves the browser demo UI
- now exposes an explicit **Cloud Gateway** vs **Local Preview** mode switch
- keeps the same portal while changing the upstream path

`GET /ui/config`

- tells the browser which gateway URLs are available
- returns the default gateway profile, model label, agent names, and trace header

`GET /ui/logs/{trace_id}`

- provides the local SSE trace feed used by the portal in local mode
- shows the synthetic hop narrative such as `kong -> maf -> foundry`

`POST /invoke`

- demonstrates **non-streaming via backend adapter**
- FastAPI receives JSON, calls `agent.run(...)`, waits for the full result, and returns JSON

`POST /stream`

- demonstrates **streaming via backend adapter**
- FastAPI calls `agent.run(..., stream=True)` and converts incremental MAF updates into browser-friendly SSE frames

`GET /health`

- validates that the local server is up and the MAF agent can be constructed

### Local Kong routes

These are declared in `kong/kong.yaml`.

`POST /invoke`

- Kong fronts the local FastAPI non-streaming adapter

`POST /stream`

- Kong fronts the local FastAPI streaming adapter
- buffering is disabled so SSE stays incremental

`GET /portal`, `GET /ui/*`, `GET /health`

- Kong can front the UI and control-plane routes, not just the agent calls

### Azure Kong route

This is declared in `kong/kong.azure.template.yaml`.

`POST /responses`

- demonstrates **native Hosted Agent protocol pass-through**
- Kong injects the managed-identity bearer token and Foundry preview headers
- Kong forwards the request directly to the Hosted Agent Responses endpoint
- non-streaming uses `"stream": false`
- streaming uses `"stream": true`

`GET /health`

- returns a gateway-level synthetic health response
- proves Kong is alive without hitting the Hosted Agent path

## Portal Modes

The portal now makes the operator choose the path explicitly.

### Cloud Gateway

Use this when you want the real demo path:

```text
Portal -> Azure Kong -> Foundry Hosted Agent
```

This is the mode to use for stakeholder demos, gateway policy demonstrations, and managed-identity auth validation.

### Local Preview

Use this when you want the fastest troubleshooting path:

```text
Portal -> local FastAPI adapter -> MAF agent
```

This is the mode to use when Azure Kong is not deployed yet, when Docker is unavailable, or when you need to debug the agent locally without the cloud gateway in the middle.

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
|   |-- preflight.ps1
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
|   |-- test_cloud_gateway.ps1
|   |-- test_cloud_gateway.py
|   |-- test_non_sse.py
|   |-- test_project_endpoint.py
|   +-- test_sse.py
|-- cleanup.ps1
|-- cleanup.sh
+-- README.md
```

## Prerequisites

- Python 3.10+
- Azure CLI logged into a subscription with Azure AI Foundry access
- permission to deploy `gpt-5.4-mini`
- Docker Desktop if you want the **local Kong** path

## First Run, In Order

### 1. Clone and run bootstrap preflight

```powershell
git clone https://github.com/samsonlee0907/kong-maf-demo.git
Set-Location .\kong-maf-demo
.\infra\preflight.ps1 -Mode bootstrap
```

This checks:

- Python
- Azure CLI
- Azure login state
- Docker, when needed later

### 2. Provision the Foundry base resources

```powershell
.\infra\provision.ps1
```

This creates:

- the Foundry account
- the Foundry project
- the `gpt-5.4-mini` deployment

It also writes `agent/.env`.

### 3. Deploy the cloud demo path

```powershell
.\infra\deploy_azure_demo.ps1
```

This deploys:

- the Foundry Hosted Agent
- the Azure Kong gateway in Azure Container Apps

### 4. Re-run cloud preflight

```powershell
.\infra\preflight.ps1 -Mode cloud
```

At this point, `agent/.env` should contain your project endpoint and `AZURE_KONG_GATEWAY_URL`.

### 5. Set up the local portal host

```powershell
Set-Location .\agent
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
python .\server.py
```

If `8080` is in use:

```powershell
$env:AGENT_PORT="8088"
python .\server.py
```

### 6. Validate the cloud path

In another terminal:

```powershell
Set-Location .\tests
python .\test_cloud_gateway.py
```

or:

```powershell
.\test_cloud_gateway.ps1
```

### 7. Open the portal

- [http://127.0.0.1:8080/portal](http://127.0.0.1:8080/portal)
- if using `AGENT_PORT=8088`: [http://127.0.0.1:8088/portal](http://127.0.0.1:8088/portal)

Choose:

- **Cloud Gateway** for `Portal -> Azure Kong -> Foundry Hosted Agent`
- **Local Preview** for `Portal -> local FastAPI adapter`

## Optional: Run Local Kong Too

If you also want the local Docker-based Kong path:

```powershell
.\infra\preflight.ps1 -Mode local
Set-Location .\kong
docker compose up -d
```

Then validate it:

```powershell
Set-Location ..\tests
$env:KONG_URL="http://127.0.0.1:8000"
$env:AGENT_URL="http://127.0.0.1:8080"
.\test_both.ps1
```

If your local server is on `8088`:

```powershell
$env:AGENT_URL="http://127.0.0.1:8088"
.\test_both.ps1
```

## Validation Matrix

### Foundry project smoke test

Run this after provisioning and before the local server:

```powershell
python .\tests\test_project_endpoint.py
```

This validates:

- the Foundry project endpoint
- Azure CLI credential access
- the GPT-5 request format using `max_completion_tokens`

### Cloud gateway smoke test

Run this after `deploy_azure_demo.ps1`:

```powershell
python .\tests\test_cloud_gateway.py
```

This validates:

- Azure Kong `/health`
- Azure Kong `/responses`
- managed-identity auth injection from Kong to the Hosted Agent

### Local gateway smoke test

Run this after the local server and Docker Kong are up:

```powershell
.\tests\test_both.ps1
```

This validates:

- local non-streaming `/invoke`
- local streaming `/stream`

## Deploy to Azure

The repository includes an ARM template for the Foundry bootstrap resources at `infra/azuredeploy.json`.

This button provisions:

- the Azure AI Foundry account
- the Foundry project
- the `gpt-5.4-mini` deployment

It does **not** deploy the Hosted Agent or Azure Kong. Those still require the scripts in `infra/`.

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fsamsonlee0907%2Fkong-maf-demo%2Fmain%2Finfra%2Fazuredeploy.json)

An example parameters file is included at `infra/azuredeploy.parameters.example.json`.

## Secrets and Repo Safety

Do not commit:

- `agent/.env`
- virtual environments
- runtime logs
- generated caches

Use `agent/.env.example` as the repo-safe template. The real `agent/.env` should be generated by `infra/provision.ps1` or created locally for your own subscription.

## Cleanup

Local cleanup:

```powershell
.\cleanup.ps1
```

Cross-platform cleanup:

```bash
./cleanup.sh
```

## Troubleshooting

`401` from Azure Kong `/responses`

- Kong is reachable, but the Hosted Agent call is not authorized
- redeploy with `.\infra\deploy_kong_azure.ps1`

Portal works locally but not in cloud mode

- run `python .\tests\test_cloud_gateway.py`
- if that fails, the cloud path is not healthy yet

Local Kong returns `502`

- ensure the FastAPI server is running on the port referenced by `kong/kong.yaml`
- set `AGENT_PORT` if `8080` is occupied

SSE looks buffered

- confirm local Kong is using `kong/docker-compose.yml`
- buffering must stay disabled for `/stream`
