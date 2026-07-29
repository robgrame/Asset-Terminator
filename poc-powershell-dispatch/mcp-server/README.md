# asset-terminator-mcp

MCP (Model Context Protocol) server that exposes the Asset-Terminator disposal
Function API as tools, so an AI agent can submit and track device wipe requests
without ever handling the function key directly.

## Tools

| Tool | API call | Purpose |
|------|----------|---------|
| `submit_wipe_request` | `POST /api/v1/wipe` | Queue a disposal/wipe request (validation, Intune resolution, guardrails, dispatch). Supports `dryRun`. |
| `get_wipe_status` | `GET /api/v1/wipe/status` | Read the durable state of a request by `requestId` or `serialNumber`. |

The server is a thin proxy: the AI agent calls the tools, and this process
attaches the `x-functions-key` header from the environment.

## Configuration

Set via environment variables (see `.env.example`):

| Variable | Required | Description |
|----------|----------|-------------|
| `AT_FUNCTION_BASE_URL` | yes | Base URL of the intake Function App, e.g. `https://attdisp-func-api-dev.azurewebsites.net`. |
| `AT_FUNCTION_KEY` | yes | Intake function key (`x-functions-key`). |
| `AT_FUNCTION_TIMEOUT_MS` | no | Per-request timeout in ms (default `30000`). |

Retrieve the key with:

```powershell
az functionapp function keys list `
  -g ASSET-TERMINATOR-DISPATCH-RG `
  -n attdisp-func-api-dev `
  --function-name WipeIntake `
  --query default -o tsv
```

## Build & run

```bash
npm install
npm run build
npm start        # runs dist/index.js over stdio
```

For development without a build step: `npm run dev`.

## Registering with an AI agent host

The server speaks JSON-RPC over **stdio**. Example configuration (VS Code /
Claude Desktop style `mcpServers` block):

```json
{
  "mcpServers": {
    "asset-terminator": {
      "command": "node",
      "args": ["C:/Users/robgrame/source/repos/Asset-Terminator/poc-powershell-dispatch/mcp-server/dist/index.js"],
      "env": {
        "AT_FUNCTION_BASE_URL": "https://attdisp-func-api-dev.azurewebsites.net",
        "AT_FUNCTION_KEY": "<function-key>"
      }
    }
  }
}
```

## Notes

- Business outcomes (HTTP 400 validation, 422 guardrail rejection) are returned
  as normal tool results so the agent can reason about them; only HTTP 5xx and
  transport failures are surfaced as tool errors.
- The function key is a secret: prefer injecting it through the host's `env`
  block or a local `.env` (git-ignored) rather than committing it.
