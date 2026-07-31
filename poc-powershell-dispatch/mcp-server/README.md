# Asset-Terminator remote MCP server

Azure Functions TypeScript app that publishes the Asset-Terminator API as a
native remote MCP server through the Azure Functions MCP extension.

This is not a local stdio wrapper. After deployment, MCP clients connect to:

```text
https://<mcp-function-app>.azurewebsites.net/runtime/webhooks/mcp
```

## Tools

| Tool | Backing API | Purpose |
|---|---|---|
| `submit_wipe_request` | `POST /api/v1/wipe` | Validate and queue a disposal request. Supports `dryRun`. |
| `get_wipe_status` | `GET /api/v1/wipe/status` | Retrieve state by `requestId` or `serialNumber`. |

The MCP Function App stores the API host key in `AT_FUNCTION_KEY` and attaches
it to calls to the PowerShell API. MCP clients never receive that key.

## Authentication

`host.json` keeps `webhookAuthorizationLevel` at `System`. Remote clients must
send the Azure Functions system key named `mcp_extension`:

```powershell
az functionapp keys list `
  --resource-group ASSET-TERMINATOR-DISPATCH-RG `
  --name attdisp-func-mcp-dev `
  --query systemKeys.mcp_extension `
  --output tsv
```

Example VS Code `.vscode/mcp.json`:

```json
{
  "inputs": [
    {
      "type": "promptString",
      "id": "asset-terminator-mcp-key",
      "description": "Asset-Terminator MCP extension system key",
      "password": true
    }
  ],
  "servers": {
    "asset-terminator": {
      "type": "http",
      "url": "https://attdisp-func-mcp-dev.azurewebsites.net/runtime/webhooks/mcp",
      "headers": {
        "x-functions-key": "${input:asset-terminator-mcp-key}"
      }
    }
  }
}
```

The Function App also appears under **AI (Preview)** in the Azure portal,
where the two MCP tools and connection details can be inspected.

## Local development

Prerequisites:

- Node.js 22 or later
- Azure Functions Core Tools 4.0.7030 or later
- Azurite, when using `UseDevelopmentStorage=true`

```powershell
Copy-Item local.settings.example.json local.settings.json
# Set AT_FUNCTION_KEY in local.settings.json.
npm ci
npm test
npm start
```

The local Streamable HTTP endpoint is:

```text
http://localhost:7071/runtime/webhooks/mcp
```

Business outcomes such as HTTP 400 and 422 are returned as structured tool
results. Authentication failures, throttling, server errors, timeouts and
transport failures fail the tool call.
