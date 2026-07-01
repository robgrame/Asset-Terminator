# Asset-Terminator — PowerShell single-function mock

A deliberately minimal **mockup** of the decommission flow: **one** Azure Function
(PowerShell) that combines *intake* and *processing* in a single synchronous call.
It deletes the device from **Windows Autopilot** (Windows only) and issues the
**Intune wipe**.

This is intentionally simpler than the production-shaped `poc-powershell/`
(two apps + Service Bus + state store): here everything happens inline in one
function, with no queue, no database and no Durable Functions.

## What it does

`POST /api/v1/wipe`

1. **Caller auth = Function API Key** (`authLevel: function`). Pass the key as the
   `x-functions-key` header or the `?code=` query string. **No certificate.**
2. Reads the ServiceNow request, including the **operating system type**
   (`operatingSystem`: `Windows` | `Mac` | `Mobile`).
3. Resolves the Intune managed device by `managedDeviceId`, `deviceName` and/or
   `serialNumber` (picks the freshest object when several match).
4. **If the device is Windows**, deletes it from **Windows Autopilot** first.
   For `Mac`/`Mobile` this step is skipped.
5. Issues the **Intune wipe**.

`dryRun: true` evaluates everything and calls nothing destructive.

## Configuration — everything via Application Settings

**All** configuration is read from the Function App **Application Settings**
(environment variables). Only the three `GRAPH_*` credential settings are
required; every other setting has a safe default.

| App setting | Required | Default | Description |
|---|---|---|---|
| `GRAPH_TENANT_ID` | ✅ | — | Entra tenant (directory) ID |
| `GRAPH_CLIENT_ID` | ✅ | — | App registration application (client) ID |
| `GRAPH_CLIENT_SECRET` | ✅ | — | App registration client secret |
| `GRAPH_BASE_URI` | | `https://graph.microsoft.com/beta` | Graph endpoint (`beta` or `v1.0`) |
| `GRAPH_AUTHORITY_HOST` | | `https://login.microsoftonline.com` | Entra authority host (change for sovereign clouds) |
| `GRAPH_SCOPE` | | `https://graph.microsoft.com/.default` | OAuth2 scope for the client-credentials token |
| `GRAPH_MAX_RETRIES` | | `4` | Retries on transient Graph errors (429/5xx) |
| `DEFAULT_DRY_RUN` | | `false` | Default when the request omits `dryRun` |
| `WIPE_KEEP_ENROLLMENT_DATA` | | `false` | `keepEnrollmentData` on the Intune wipe |
| `WIPE_KEEP_USER_DATA` | | `false` | `keepUserData` on the Intune wipe |

> Store `GRAPH_CLIENT_SECRET` in Key Vault and reference it from the app setting
> for anything beyond a throwaway mock.

### Required Graph application permissions (admin-consented)

| Permission | Used for |
|---|---|
| `DeviceManagementManagedDevices.Read.All` | resolve the managed device |
| `DeviceManagementManagedDevices.PrivilegedOperations.All` | issue the wipe |
| `DeviceManagementServiceConfig.ReadWrite.All` | delete from Windows Autopilot |

## Request body

```json
{
  "requestId": "CHG0012345",
  "operatingSystem": "Windows",
  "deviceName": "FC1WRK001",
  "serialNumber": "PF3ABCDE",
  "ticketNumber": "CHG0012345",
  "requestor": "servicenow@contoso.com",
  "dryRun": true
}
```

- `operatingSystem` — **required**. Accepted (case-insensitive): `Windows`/`win`,
  `Mac`/`macOS`/`osx`, `Mobile`/`iOS`/`iPadOS`/`Android`. Only `Windows` triggers
  the Autopilot deletion.
- One of `managedDeviceId`, `deviceName` or `serialNumber` is **required**.
- `serialNumber` is required to delete a Windows device from Autopilot (falls back
  to the serial reported by Intune if omitted).

Sample payloads are in [`samples/`](./samples).

## Response

```json
{
  "requestId": "CHG0012345",
  "correlationId": "…",
  "overallStatus": "Completed",
  "operatingSystem": "Windows",
  "dryRun": false,
  "device": { "id": "…", "deviceName": "FC1WRK001", "serialNumber": "PF3ABCDE", "os": "Windows" },
  "actions": [
    { "Action": "AutopilotDelete", "Outcome": "Deleted",  "Detail": "…" },
    { "Action": "Wipe",            "Outcome": "Issued",    "ManagedDeviceId": "…", "ExecutedAt": "…" }
  ]
}
```

`overallStatus`: `Completed` (real run), `DryRun`, or `Failed` (wipe error → HTTP 502).

## Run locally

```powershell
Copy-Item local.settings.json.example local.settings.json
# fill in GRAPH_TENANT_ID / GRAPH_CLIENT_ID / GRAPH_CLIENT_SECRET
func start
```

```powershell
$body = Get-Content .\samples\request-windows.json -Raw
Invoke-RestMethod -Method Post -Uri 'http://localhost:7071/api/v1/wipe' `
  -ContentType 'application/json' -Body $body
```

## Deploy to Azure

```powershell
func azure functionapp publish <function-app-name>

az functionapp config appsettings set -g <rg> -n <function-app-name> --settings `
  GRAPH_TENANT_ID=<tenant> GRAPH_CLIENT_ID=<appId> GRAPH_CLIENT_SECRET=<secret> DEFAULT_DRY_RUN=false
```

Call it with the function key:

```powershell
$key  = az functionapp function keys list -g <rg> -n <function-app-name> --function-name WipeDevice --query default -o tsv
$body = Get-Content .\samples\request-windows.json -Raw
Invoke-RestMethod -Method Post -Uri "https://<function-app-name>.azurewebsites.net/api/v1/wipe" `
  -Headers @{ 'x-functions-key' = $key } -ContentType 'application/json' -Body $body
```

## Files

```
poc-powershell-mock/
├─ host.json
├─ profile.ps1
├─ requirements.psd1
├─ local.settings.json.example
├─ Modules/
│  └─ Graph.psm1          # secret auth + Graph REST + device/autopilot/wipe helpers
├─ WipeDevice/
│  ├─ function.json       # httpTrigger, authLevel: function (API key)
│  └─ run.ps1             # combined intake + processing
└─ samples/               # request-windows / request-mac / request-mobile
```
