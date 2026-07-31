# PoC PowerShell — Dispatch su Service Bus + runbook di piattaforma

Evoluzione di [`poc-powershell-mock`](../poc-powershell-mock/): la Function **non
esegue più il wipe**. Riceve la richiesta da ServiceNow, la valida, la mette su
un **topic Service Bus** e un **worker di backend** instrada la richiesta verso
il **runbook Azure Automation specifico per piattaforma** già in uso presso il
cliente.

Il razionale, le alternative valutate e i gap dei runbook attuali sono
documentati in [`docs/evoluzione-dispatch-runbook.md`](../docs/evoluzione-dispatch-runbook.md).

## Architettura

```
ServiceNow ──POST /api/v1/wipe──▶ Function App "api"  (WipeIntake, GetStatus)
                                      │  validazione + guardrail + stato
                                      ▼
                            Service Bus topic  asset-disposal
                              ├─ sub windows (platform='Windows')
                              ├─ sub apple   (platform='Apple')
                              └─ sub android (platform='Android')
                                      ▼
                             Function App "worker"
                              ├─ DispatchWindows ─┐
                              ├─ DispatchApple  ──┼─▶ Azure Automation runbook
                              ├─ DispatchAndroid ─┘   (ARM job idempotente)
                              └─ JobMonitor (timer) ─▶ callback ServiceNow
                                      ▲
                             Table Storage  wiperequests  (stato + evidenze)

MCP Client ──Streamable HTTP──▶ Function App "mcp" (Node 22)
                                  ├─ submit_wipe_request ─▶ API Function
                                  └─ get_wipe_status ─────▶ API Function
```

### Perché tre Function App

Le tre app girano sullo **stesso App Service Plan** (nessun piano aggiuntivo) e
hanno **identità gestite distinte**:

| App | Trigger | Permessi |
|---|---|---|
| `api` | HTTP (pubblico) | Graph *read-only*, Service Bus **Sender**, Table |
| `worker` | Service Bus + timer (nessun endpoint pubblico) | Service Bus **Receiver**, Automation **Job Operator**, Table |
| `mcp` | MCP Streamable HTTP | Storage host, chiamate HTTPS alla `api` con host key |

L'app esposta su internet non ha quindi alcun permesso per far partire un wipe:
può solo accodare una richiesta.

La Function App MCP è separata perché una Function App usa un solo worker
runtime: `api` e `worker` sono PowerShell 7.4, mentre il trigger MCP nativo non
supporta PowerShell e viene pubblicato come TypeScript su Node.js 22.

## Remote MCP server

La Function App `attdisp-func-mcp-<env>` pubblica due tool nativi tramite
**Azure Functions MCP**, visibili anche nella sezione **AI (Preview)** del
portale:

| Tool | Operazione |
|---|---|
| `submit_wipe_request` | Valida e accoda una richiesta; supporta `dryRun` |
| `get_wipe_status` | Legge lo stato per `requestId` o `serialNumber` |

Endpoint Streamable HTTP:

```text
https://attdisp-func-mcp-dev.azurewebsites.net/runtime/webhooks/mcp
```

L'endpoint richiede la system key Functions `mcp_extension`, distinta dalla
host key dell'API:

```powershell
$mcpKey = az functionapp keys list `
  --resource-group ASSET-TERMINATOR-DISPATCH-RG `
  --name attdisp-func-mcp-dev `
  --query systemKeys.mcp_extension `
  --output tsv
```

Il client passa `$mcpKey` nell'header `x-functions-key`. La host key usata per
chiamare `WipeIntake` e `GetStatus` rimane invece negli App Settings della
Function MCP e viene configurata automaticamente da `deploy.ps1` dopo la
pubblicazione dell'API.

Configurazione VS Code:

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

Dettagli di sviluppo e test sono in [`mcp-server/README.md`](mcp-server/README.md).

## Contratto REST

### `POST /api/v1/wipe`

```jsonc
{
  "requestId": "SNOW-RITM0012345",   // opzionale: chiave di idempotenza
  "operatingSystem": "Windows",       // Windows | macOS | iOS | Android | Mobile
  "scenario": "Disposal",             // Retirement | Sale | Disposal | LostStolen
  "serialNumber": "5CG1234ABC",
  "imei": "358240051111110",          // opzionale (Android/KME)
  "deviceName": "FC1WRK001",          // opzionale
  "managedDeviceId": "...",           // opzionale
  "mdmServerId": "...",               // opzionale (Apple ABM)
  "userConfirmed": true,              // guardrail di processo
  "callbackUrl": "https://.../callback",
  "dryRun": false
}
```

Risposte:

| Codice | Significato |
|---|---|
| `202` | Richiesta accodata. Header `Location: /api/v1/wipe/status?requestId=...` |
| `200` | `requestId` già visto → stato corrente, `duplicate: true` |
| `400` | Payload non valido |
| `422` | `status: Rejected` + `reason` (`DeviceNotManagedByIntune`, `GuardrailFailed`, `AmbiguousPlatform`) → ServiceNow apre un task manuale |
| `502` | Graph non raggiungibile |

`operatingSystem: "Mobile"` è ambiguo: l'intake risolve iOS vs Android
interrogando `managedDevices.operatingSystem` in Intune prima di instradare.

### `GET /api/v1/wipe/status?requestId=...`

Restituisce lo stato dalla macchina a stati:

```
Accepted → Queued → Dispatching → Dispatched → Running → Completed
                                                       ↘ PartiallyCompleted
                                                       ↘ Failed
Rejected (guardrail)   DispatchFailed (runbook non avviabile)
```

`PartiallyCompleted` copre il caso "unenrollment riuscito ma wipe fallito", che
il processo deve poter distinguere da un successo pieno.

## Meccanismo di dispatch

Il worker crea il job con
`PUT .../automationAccounts/{aa}/jobs/{jobName}?api-version=2023-11-01` usando la
managed identity. Il `jobName` è il `requestId`, quindi **un replay del messaggio
non crea un secondo job**.

I **webhook non sono supportati**: il token vive nell'URL (quindi finisce nei log
e negli script client), non sono idempotenti e non restituiscono lo stato del
job. I tre runbook in `runbooks/` sono stati adattati per accettare parametri
nominali, eliminando il ramo `$WebhookData` dell'originale.

### Routing table (`RUNBOOK_MAP`)

```jsonc
{
  "Windows": {
    "runbook": "RBK-WindowsDisposal",
    "parameters": {
      "SerialNumbers": "$.device.serialNumber",
      "RequestId": "$.requestId",
      "Scenario": "$.scenario",
      "DryRun": "$.options.dryRun"
    },
    "timeoutMinutes": 20
  },
  "Apple": {
    "runbook": "RBK-AppleDisposal",
    "parameters": {
      "SerialNumbers": "$.device.serialNumber",
      "MdmServerId": "$.options.mdmServerId",
      "RequestId": "$.requestId",
      "Scenario": "$.scenario",
      "DryRun": "$.options.dryRun"
    },
    "timeoutMinutes": 45
  },
  "Android": {
    "runbook": "RBK-AndroidDisposal",
    "parameters": {
      "Serials": "$.device.serialNumber",
      "RequestId": "$.requestId",
      "Scenario": "$.scenario",
      "DryRun": "$.options.dryRun"
    },
    "timeoutMinutes": 20
  }
}
```

I valori `$.a.b` sono percorsi JSON valutati sul messaggio canonico: aggiungere
una piattaforma (es. Android Zero-Touch) è una modifica di configurazione, non di
codice.

## Segreti: Automation Variables

I runbook **non accettano segreti come parametri**: i parametri di un job
Automation sono memorizzati in chiaro nei metadati del job e sono leggibili da
chiunque abbia il ruolo Job Reader. Ogni credenziale viene letta da una
Automation Variable tramite `Get-RequiredAutomationVariable`, che fallisce con un
messaggio esplicito se la variabile manca o è vuota.

Il template crea le variabili; quelle segrete sono create **vuote e cifrate** e
vanno popolate dopo il deploy (portale o `az automation variable update`).

| Variabile | Cifrata | Usata da | Contenuto |
|---|---|---|---|
| `ClientId` | no | tutti | App registration (application) ID per Graph |
| `TenantId` | no | tutti | Tenant ID Entra |
| `GraphCertificateName` | no | tutti | Nome dell'**Automation Certificate asset** con il certificato Graph app-only (default `GraphAppCert`) |
| `Certificate_thumbprint` | sì | tutti | Thumbprint del certificato app-only (validazione + fallback su cert store) |
| `ClientSecret` | sì | tutti | Client secret dell'app registration. **Fallback opzionale**: usato dai runbook solo se non è disponibile alcun certificato |
| `ABM-ClientId` | sì | Apple | Client ID API Apple Business Manager |
| `ABM-KeyId` | sì | Apple | Key ID API ABM |
| `ABM-PrivateKey` | sì | Apple | Chiave privata EC P-256 in PEM |
| `KME-ClientIdentifier` | sì | Android | Client identifier Knox |
| `KME-KeysJson` | sì | Android | Keys JSON Knox (contiene la chiave RSA privata) |
| `KME-CustomerId` | sì | Android | Customer ID Knox |

> **Autenticazione Graph app-only (runbook).** I runbook si autenticano a
> Microsoft Graph con questo **ordine di preferenza**: (1) **certificato**
> dall'Automation Certificate asset (default `GraphAppCert`, recuperato con
> `Get-AutomationCertificate` e passato a `Connect-MgGraph -Certificate`);
> (2) certificato già presente nel cert store del sandbox, referenziato via
> `Certificate_thumbprint`; (3) **client secret** dalla variabile cifrata
> `ClientSecret`, usato **solo come ultima risorsa** se non è disponibile alcun
> certificato. Il certificato è l'opzione raccomandata. Esempio di caricamento
> del certificato:
>
> ```powershell
> az automation certificate create `
>   --resource-group ASSET-TERMINATOR-DISPATCH-RG `
>   --automation-account-name attdisp-auto-dev `
>   --name GraphAppCert `
>   --path .\graph-app.pfx `
>   --password '<pfx-password>'
> ```

## Deploy

```powershell
cd poc-powershell-dispatch/infra

./deploy.ps1 `
    -ResourceGroup ASSET-TERMINATOR-DISPATCH-RG `
    -Subscription  <subscription-id> `
    -Location      westeurope `
    -GraphTenantId <tenant> `
    -GraphClientId <appId> `
    -GraphClientSecret <secret>
```

Lo script provisiona l'infrastruttura, sincronizza i moduli condivisi
(`build.ps1`), compila il progetto TypeScript e pubblica **tutte e tre** le
Function App.

Il runtime Azure Automation `PowerShell-74` include automaticamente
`Microsoft.Graph.Authentication` 2.30.0, richiesto dai tre runbook per
l'autenticazione app-only a Graph.

L'app registration Graph serve solo per le letture dell'intake:

- `DeviceManagementManagedDevices.Read.All` (application, con consenso admin)

I permessi di wipe restano sull'app registration usata dai runbook, non su questa.

> Nota: `func azure functionapp publish` reimposta la subscription di default di
> `az`. Ogni comando `az` successivo deve passare `--subscription` esplicito
> (`deploy.ps1` lo fa già).

### Connettività privata

Come per il PoC mock, la subscription applica una policy che forza
`publicNetworkAccess=Disabled` su storage e Service Bus. Il template crea quindi
VNet, subnet delegata, private endpoint e private DNS zone. Per un ambiente senza
quella policy si può disattivare con `usePrivateEndpoints=false`.

### Import dei runbook

Il template crea i tre runbook **vuoti**; `deploy.ps1` ne carica il contenuto da
`runbooks/` e li pubblica, così una modifica al codice del runbook non è una
modifica al template. Non serve nessun passo manuale.

Dopo il deploy vanno popolate le Automation Variable cifrate (vedi la tabella
"Segreti: Automation Variables") e va caricato in Automation il certificato usato
per l'autenticazione app-only a Graph.

## Runbook: cosa è stato corretto

I runbook in `runbooks/` derivano da quelli del cliente, con questi fix:

| Runbook | Problema originale | Gravità |
|---|---|---|
| Windows | `:IsNullOrWhiteSpace(...)` invece di `[string]::IsNullOrWhiteSpace(...)` (3x) | bloccante |
| Windows | assegnazione a `$matches`, variabile automatica | alta |
| Windows | `"Serial=$serial: ..."` interpretato come scope reference | bloccante |
| Apple | header `Authorization = "******"` letterale: ogni chiamata ABM va in 401 | bloccante |
| Apple | esito dell'activity di unassign mai verificato | alta |
| Apple | `Start-Sleep` cieco di 15 minuti in attesa del sync DEP | media |
| Android | accettava **solo** `$WebhookData`, `throw` senza | bloccante |
| Android | `Escape-ODataString`: verbo non approvato e funzione inesistente | media |
| Android | `Get-Date -UFormat %s` per lo `iat` del JWT: dipende dal locale | media |
| Android | errori di wipe emessi con `Write-Error`: il job restava `Completed` | alta |
| tutti | nessun output strutturato per ServiceNow | alta |
| tutti | segreti passati come parametri o hardcoded | alta |

Contratto comune dei tre runbook:

* parametri `-RequestId`, `-Scenario` (`Retirement`/`Sale`/`Disposal`/`LostStolen`),
  `-DryRun`, più i parametri di piattaforma;
* `-DryRun` è una **stringa**, non un `[bool]`: Automation passa i parametri come
  stringhe e `[bool]"false"` vale `$true`;
* tutti i segreti letti dalle Automation Variables, mai dai parametri;
* riga finale `##RESULT## {json}` con `requestId, platform, scenario, dryRun,
  wipeIssued, devices[], errors[], startedAt, completedAt`, emessa **anche sui
  percorsi di errore**;
* `throw` finale se `wipeIssued = $false`, così lo stato del job Automation
  riflette l'esito di business;
* le fasi di deregistrazione (ABM unassign, Knox delete) sono best-effort: un
  disservizio di Apple o Samsung non impedisce il wipe Intune.

Gli script client del cliente che invocano i webhook contengono i **token in
chiaro nell'URL**: vanno revocati e rigenerati, e non vanno versionati.

## Struttura

```
poc-powershell-dispatch/
├── build.ps1                 sincronizza shared/Modules → api/ e worker/
├── shared/Modules/           AT.Common, AT.Graph, AT.State, AT.Messaging,
│                             AT.Automation, AT.Dispatch
├── api/                      WipeIntake (POST), GetStatus (GET)
├── worker/                   DispatchWindows/Apple/Android, JobMonitor
├── runbooks/                 i tre runbook di piattaforma corretti
├── infra/main.bicep          infrastruttura completa
├── infra/deploy.ps1          provisioning + publish
└── samples/                  payload di esempio
```

`api/Modules` e `worker/Modules` sono generate da `build.ps1`: non modificarle a
mano, la sorgente è `shared/Modules`.
