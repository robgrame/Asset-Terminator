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
```

### Perché due Function App

`api` e `worker` girano sullo **stesso App Service Plan** (nessun costo
aggiuntivo) ma hanno **identità gestite distinte**:

| App | Trigger | Permessi |
|---|---|---|
| `api` | HTTP (pubblico) | Graph *read-only*, Service Bus **Sender**, Table |
| `worker` | Service Bus + timer (nessun endpoint pubblico) | Service Bus **Receiver**, Automation **Job Operator**, Table |

L'app esposta su internet non ha quindi alcun permesso per far partire un wipe:
può solo accodare una richiesta.

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

### Deploy semplificato con endpoint pubblici

Se la subscription non richiede connettività privata, aggiungere
`-PublicEndpoints`. Il deploy usa `infra/main-public.bicep` e non crea VNet,
private endpoint o zone DNS private. Storage e Service Bus continuano a usare
managed identity e RBAC, ma sono raggiungibili attraverso gli endpoint di rete
pubblici:

```powershell
cd poc-powershell-dispatch/infra

./deploy.ps1 `
    -ResourceGroup DeviceLifecycleAction `
    -Subscription <subscription-id> `
    -Location westeurope `
    -NamePrefix attdisp02 `
    -Env dev `
    -GraphTenantId <tenant-id> `
    -GraphClientId <app-id> `
    -GraphClientSecret <secret> `
    -PublicEndpoints
```

Questa variante non è compatibile con Azure Policy che impongono
`publicNetworkAccess=Disabled` per Storage o Service Bus.

Lo script provisiona l'infrastruttura, genera i `run.ps1` autosufficienti
(`build.ps1`) e pubblica **entrambe** le Function App.

Il deploy usa PowerShell 7.6 per entrambe le Function App e crea il Runtime
Environment Automation `PowerShell-76`, nel quale installa
`Microsoft.Graph.Authentication` prima di collegare e pubblicare i runbook. La
versione predefinita del modulo è `2.39.0` e può essere modificata con
`-GraphAuthenticationModuleVersion`; il runtime può essere sovrascritto con
`-PowerShellVersion`.

PowerShell 7.6 è generalmente disponibile per Azure Automation. Nelle Azure
Functions è esposto dallo stack Linux `PowerShell|7.6`; verificare la
disponibilità nella regione con `az functionapp list-runtimes --os linux` prima
del deploy.

### Test end-to-end

Il test E2E invia una richiesta con `dryRun=true`, verifica la risposta `202` e
interroga lo stato fino a `Completed`:

```powershell
cd poc-powershell-dispatch

./tests/Invoke-DispatchE2E.ps1 `
    -ResourceGroup DeviceLifecycleAction `
    -FunctionAppName attdisp02-func-api-dev `
    -Subscription <subscription-id> `
    -SerialNumber <serial-number-Intune>
```

Il seriale deve identificare un dispositivo gestito da Intune. Usare `-Real`
solo per eseguire intenzionalmente un wipe effettivo. Il test restituisce un
exit code non zero se l'intake non accetta la richiesta, il polling scade o lo
stato terminale è diverso da quello atteso.

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
├── build.ps1                 genera run.ps1 autosufficienti con moduli embedded
├── shared/Modules/           AT.Common, AT.Graph, AT.State, AT.Messaging,
│                             AT.Automation, AT.Dispatch
├── api/                      WipeIntake (POST), GetStatus (GET)
├── worker/                   DispatchWindows/Apple/Android, JobMonitor
├── runbooks/                 i tre runbook di piattaforma corretti
├── infra/main.bicep          infrastruttura completa
├── infra/deploy.ps1          provisioning + publish
└── samples/                  payload di esempio
```

Ogni Function mantiene il proprio handler in `handler.ps1`. `build.ps1` genera
il relativo `run.ps1`, incorporando integralmente i moduli richiesti da
`shared/Modules`. In questo modo il codice pubblicato e revisionabile nella
cartella della Function è completo, mentre le modifiche continuano ad avere
un'unica sorgente. Non modificare direttamente i `run.ps1` generati. Il deploy
verifica che tutti i `run.ps1` contengano i moduli embedded, che non importino
`../Modules/AT.*.psm1` e che gli `handler.ps1` siano esclusi dal pacchetto.
