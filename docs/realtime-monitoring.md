# Realtime monitoring PoC — SignalR (Serverless) + Event Grid

Live operations board that pushes decommission state changes to the browser in real time.

## Flow

```
Orchestrator / Reconciliation
  → IOperationalTelemetry.RequestSnapshotAsync (existing seam)
  → RealtimeBroadcastTelemetry decorator
  → EventGridRealtimeEventPublisher  ──(AssetTerminator.DecommissionStateChanged)──▶  Event Grid custom topic
                                                                                        │
                                                                                        ▼
                                              Function OnDecommissionStateChanged (EventGridTrigger)
                                                                                        │  [SignalROutput hub "decommissions"]
                                                                                        ▼
                                                          Azure SignalR Service (Serverless)
                                                                                        │
                                                                                        ▼
                                              Browser board (served by the Function at `/`, negotiates at `/negotiate`)
```

## Components

| Concern | Project / Resource |
| --- | --- |
| Event DTO | `src/AssetTerminator.Contracts/RealtimeStateChange.cs` |
| Publisher abstraction | `src/AssetTerminator.Core/Abstractions/IRealtimeEventPublisher.cs` |
| Options (`AssetTerminator:Realtime`) | `src/AssetTerminator.Core/Options/Options.cs` (`RealtimeOptions`) |
| Event Grid publisher | `src/AssetTerminator.Infrastructure/Realtime/EventGridRealtimeEventPublisher.cs` |
| No-op fallback | `src/AssetTerminator.Infrastructure/Realtime/NullRealtimeEventPublisher.cs` |
| Telemetry decorator (integration seam) | `src/AssetTerminator.Infrastructure/Realtime/RealtimeBroadcastTelemetry.cs` |
| EventGrid → SignalR bridge | `src/AssetTerminator.Realtime.Functions/Functions/OnDecommissionStateChanged.cs` |
| Board page + `/negotiate` | `src/AssetTerminator.Realtime.Functions/Functions/HttpEndpoints.cs` + `board.html` |
| Razor Web App (alternative frontend) | `src/AssetTerminator.Realtime.Web/` |
| Infrastructure | `infra/realtime.bicep` |

### Frontend note
The user-selected **Razor Web App** (`AssetTerminator.Realtime.Web`) is kept in the repo and builds
cleanly. It is **not** part of the deployed PoC because the target subscription has **0 App Service
VM quota in North Europe** (both Basic B1 and Free F1 Linux plans consume dedicated VM quota and are
rejected). To keep the PoC fully serverless, the board is served directly by the Flex Consumption
Function App (`/` and `/negotiate`). Deploy the Razor app to any environment with App Service quota,
setting `Azure:SignalR:Endpoint` (identity) or `Azure:SignalR:ConnectionString`.

## Integration (zero call-site changes)
`RealtimeBroadcastTelemetry` decorates `IOperationalTelemetry`, whose `RequestSnapshotAsync` already
fires on every state change (IntakeService, CallbackPublisher, DecommissionActivities,
ReconciliationService). The decorator publishes to Event Grid then delegates to the inner telemetry,
so no orchestration code was touched. The publisher only activates when
`AssetTerminator:Realtime:TopicEndpoint` is configured; otherwise it is a no-op.

## Deploy

```powershell
az deployment group create -g ASSET-TERMINATOR-RG -n realtime-poc `
  --template-file infra/realtime.bicep `
  --parameters namePrefix=astterm env=dev location=northeurope `
  --parameters appInsightsConnectionString="<appi-conn-string>" `
  --parameters orchestratorPrincipalId="<orchestrator-uami-principalId>" `
  --parameters createEventSubscription=false
```

Then wire the orchestrator (already done for `dev`):

```powershell
az functionapp config appsettings set -g ASSET-TERMINATOR-RG -n astterm-func-orchestrator-dev --settings `
  "AssetTerminator__Realtime__TopicEndpoint=https://astterm-egt-decom-dev.northeurope-1.eventgrid.azure.net/api/events" `
  "AssetTerminator__Realtime__EventType=AssetTerminator.DecommissionStateChanged"
```

The template grants the orchestrator UAMI **EventGrid Data Sender** on the topic and the function
UAMI **SignalR Service Owner** + storage data roles.

## Deployed resources (dev)
- Azure SignalR `astterm-sigr-dev` (Free_F1, Serverless)
- Event Grid topic `astterm-egt-decom-dev`
- Function App `astterm-func-realtime-dev` (Flex Consumption, dotnet-isolated 10)
- UAMI `astterm-uami-realtime-dev`, storage `asttermrtfndev…`

## Known limitations (PoC)
- **Anonymous access.** The board (`/`) and `/negotiate` are anonymous and SignalR CORS allows all
  origins, so anyone who can reach the function URL can subscribe to ticket/device/state broadcasts.
  Before production: put the function behind Entra (Easy Auth), restrict SignalR CORS to the frontend
  origin, and issue negotiate tokens only to authenticated users.
- **No initial snapshot / replay.** SignalR has no message replay and Event Grid is at-least-once and
  unordered. A client opening or reconnecting misses prior events. The board drops stale/duplicate
  updates by comparing `UpdatedAt` per row, but for a complete view it should also load an
  authoritative snapshot (e.g. from the state store / KQL) on load and after reconnect.
- **Coverage.** Broadcasts fire wherever `IOperationalTelemetry.RequestSnapshotAsync` is called
  (intake, `EnrichAndValidate` → Validated, and callback publication). Transitions that neither emit
  a callback nor call the seam will not appear until the next event.

## ⚠️ Known blocker: function code publish
The target subscription enforces an **Azure Policy that disables storage shared-key access**
(`allowSharedKeyAccess=false`, non-overridable). The Flex Consumption Kudu deployment pipeline's
`StorageAccessibleCheck` fails with **403** when uploading the zip, for both system-assigned and
user-assigned identity configurations (`func azure functionapp publish` and `az functionapp deploy`
both fail — the latter with 415 as Flex rejects that endpoint).

The infrastructure, RBAC, and orchestrator wiring are complete; only the function **code** could not
be pushed from this environment. To finish the PoC once publishing is unblocked:

1. Publish the function code:
   ```powershell
   cd src/AssetTerminator.Realtime.Functions
   func azure functionapp publish astterm-func-realtime-dev --dotnet-isolated
   ```
   If the 403 persists, publish from an environment/identity permitted to write to the deployment
   container, or request a policy exemption for the realtime storage account.
2. Create the Event Grid → Function subscription (the function must exist first):
   ```powershell
   az deployment group create -g ASSET-TERMINATOR-RG -n realtime-poc `
     --template-file infra/realtime.bicep `
     --parameters namePrefix=astterm env=dev location=northeurope `
     --parameters appInsightsConnectionString="<appi>" `
     --parameters orchestratorPrincipalId="79b63f37-7a15-4a9d-bc8a-922956136e45" `
     --parameters createEventSubscription=true
   ```
3. Open `https://astterm-func-realtime-dev.azurewebsites.net/` — the live board connects via
   `/negotiate` to Azure SignalR and updates as decommission requests change state.
