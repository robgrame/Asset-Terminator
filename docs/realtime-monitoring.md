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

### Root cause (re-diagnosed)
The blocker was originally attributed to the Azure Policy that disables storage shared-key access
(`allowSharedKeyAccess=false`). That is **not** the cause: Flex Consumption fully supports
identity-based deployment storage, and `realtime.bicep` already configures it correctly
(`deployment.storage.authentication.type = UserAssignedIdentity` + `Storage Blob Data Owner` on the
UAMI).

The actual cause is a **network** one. Policy also forces `publicNetworkAccess = Disabled` on every
storage account in the subscription, while `networkRuleSet.bypass` is `None` and **no private
endpoint exists**:

```
asttermrtfndevfqe3fiq2eh   sharedKey=False  publicNet=Disabled  bypass=None  privateEndpoints=0
```

So the storage account is unreachable by *anything* — the deploying client, and the Functions
platform itself. The 403 raised by `StorageAccessibleCheck` is a network denial, not an
authorization one. Confirmed with `az storage blob list --auth-mode login`, which returns
*"The request may be blocked by network rules of storage account"*.

> This affects the **whole `dev` environment**, not just the realtime PoC: `astterm-func-api-dev`
> and `astterm-func-orchestrator-dev` sit on identically locked-down storage accounts, have no VNet
> integration either, and their hosts are likewise unreachable (`az functionapp function list`
> returns `Request Timeout`).

### Fix: private endpoints + VNet integration
Private endpoints alone are not enough — the apps need a route into the VNet, and DNS must resolve
the storage FQDNs to the private IPs. All three pieces are provided by
[`infra/modules/network.bicep`](../infra/modules/network.bicep):

1. A VNet with an **app subnet delegated to `Microsoft.App/environments`** (the delegation Flex
   Consumption requires; `/27` minimum) and a **separate subnet for the private endpoints** — Flex
   forbids sharing the delegated subnet with private endpoints.
2. **blob / queue / table** private endpoints for each storage account (queue is required by
   Durable Functions, blob and table by the Functions host).
3. The matching **Private DNS zones** (`privatelink.<sub>.core.windows.net`), linked to the VNet
   with private DNS zone groups.

```powershell
az deployment group create -g ASSET-TERMINATOR-RG -n network `
  --template-file infra/modules/network.bicep `
  --parameters namePrefix=astterm env=dev location=northeurope `
  --parameters storageAccountNames="['asttermrtfndevfqe3fiq2eh','asttermapiflexdevi3waevy','asttermorchflexdevi3waev']"
```

Then bind each function app to the delegated subnet (`appSubnetId` output):

```powershell
az functionapp vnet-integration add -g ASSET-TERMINATOR-RG -n astterm-func-realtime-dev `
  --vnet astterm-vnet-dev --subnet snet-functions
```

> **The deploying client also needs a network path.** Your workstation and any hosted CI runner sit
> outside the VNet, so the zip upload still fails from there. Publish from an agent inside the VNet
> (self-hosted runner / VM / Container Apps job), over VPN or ExpressRoute, or temporarily add your
> IP to the storage firewall if policy allows it.

The infrastructure, RBAC, and orchestrator wiring are otherwise complete. To finish the PoC:

1. Publish the function code (from inside the VNet, see above):
   ```powershell
   cd src/AssetTerminator.Realtime.Functions
   func azure functionapp publish astterm-func-realtime-dev --dotnet-isolated
   ```
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
