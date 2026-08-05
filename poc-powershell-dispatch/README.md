# PoC PowerShell — Function unica + runbook di piattaforma

Evoluzione di [`poc-powershell-mock`](../poc-powershell-mock/): la Function **non
esegue il wipe direttamente**. Riceve la richiesta da ServiceNow, la valida,
salva lo stato e avvia subito il **runbook Azure Automation specifico per
piattaforma** già in uso presso il cliente.

Il razionale, le alternative valutate e i gap dei runbook attuali sono
documentati in [`docs/evoluzione-dispatch-runbook.md`](../docs/evoluzione-dispatch-runbook.md).

## Architettura

```
ServiceNow ──POST /api/v1/wipe──▶ Function App
                                  ├─ WipeIntake
                                  │   validazione + guardrail + persistenza
                                  │   └─▶ Azure Automation runbook (ARM)
                                  ├─ GetStatus (HTTP)
                                  └─ JobMonitor (timer) ─▶ callback ServiceNow
                                           ▲
                                  Table Storage wiperequests
```

### Una sola Function App

La Function App usa una sola identità gestita:

| Trigger | Funzione | Permessi |
|---|---|---|
| HTTP | `WipeIntake`, `GetStatus` | Graph *read-only*, Table, Automation **Job Operator** |
| Timer | `JobMonitor` | Table, Automation **Job Operator** |

Service Bus non è necessario: dopo il write-before-action, `WipeIntake` crea
direttamente il job Automation con una chiamata ARM idempotente.
Un lease atomico nella tabella di stato impedisce l'avvio concorrente di due
richieste con `requestId` diversi sullo stesso seriale.

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
| `202` | Richiesta accettata in modo durevole (`Accepted`), o runbook avviato/confermato (`Dispatched`, temporaneamente `Dispatching` durante retry/recovery), oppure dry-run completato (`Completed`). Header `Location: /api/v1/wipe/status?requestId=...` |
| `200` | `requestId` già visto con lo **stesso** contenuto → stato corrente, `duplicate: true` |
| `400` | Payload non valido |
| `409` | `requestId` già usato con contenuto **diverso** (nessun overwrite), oppure esiste già una richiesta attiva per lo stesso dispositivo |
| `422` | `status: Rejected` + `reason` (`DeviceNotManagedByIntune`, `GuardrailFailed`, `AmbiguousPlatform`, `PlatformMismatch`, `DeviceIdentityMismatch`, `MissingSerialNumber`) → ServiceNow apre un task manuale. Ogni `Rejected` è persistito: `GetStatus` non risponde mai `404` per un `requestId` che ha raggiunto questa fase |
| `502` | Graph non raggiungibile (solo errori genuini, es. throttling/RBAC: un device realmente non gestito resta `422`) |

`operatingSystem: "Mobile"` è ambiguo: l'intake risolve iOS vs Android
interrogando `managedDevices.operatingSystem` in Intune prima di instradare, e
rifiuta (`PlatformMismatch`) una piattaforma dichiarata esplicitamente che non
corrisponde al valore autorevole in Intune.

L'attempt di dispatch immediato eseguito da `WipeIntake` è **best-effort**: la
riga durevole (`Accepted`, con il payload canonico completo) viene scritta
*prima* di qualunque chiamata ad Automation, quindi un riavvio del Function
App, un timeout ARM o un 429/5xx non perdono mai la richiesta. `JobMonitor`
riconcilia (claim atomico via ETag, backoff esponenziale, tentativi limitati)
tutto ciò che non è stato confermato inline.

### `GET /api/v1/wipe/status?requestId=...`

Restituisce lo stato dalla macchina a stati:

```
Accepted → Dispatching → Dispatched → Running → EvidencePending → Completed
                                                                  ↘ PartiallyCompleted
                                                                  ↘ Failed (evidenceState=EvidenceMissing)
Rejected (guardrail/validazione)   DispatchFailed (tentativi esauriti)
```

`PartiallyCompleted` copre il caso "unenrollment riuscito ma wipe fallito", che
il processo deve poter distinguere da un successo pieno. `EvidencePending`
copre il caso in cui il job Automation è già terminale ma l'output con la riga
`##RESULT##` non è ancora leggibile: viene ritentato un numero limitato di
volte prima di fallire come `Failed`/`evidenceState=EvidenceMissing`.

La risposta include anche, quando disponibili: `attempts`, `nextAttemptAt`,
`dispatchOutcome`, `payloadHash`, `evidenceState`, `eventId`,
`callbackStatus`/`callbackAttempts`/`callbackNextAttemptAt`/`callbackError` e,
per compatibilità con la precedente architettura basata su coda Service Bus,
`queuedAt` (sempre uguale ad `acceptedAt`).

## Meccanismo di dispatch

`WipeIntake` crea il job con
`PUT .../automationAccounts/{aa}/jobs/{jobName}?api-version=2023-11-01` usando la
managed identity. Il `jobName` è il `requestId`, quindi **ripetere la richiesta
non crea un secondo job**. Se la risposta della PUT è ambigua (timeout, `429`,
`5xx`), il dispatcher esegue una GET di conferma prima e dopo il tentativo:
solo una GET che conferma l'assenza del job autorizza un nuovo tentativo di
PUT; se anche la GET di conferma fallisce, lo stato resta "sconosciuto" (mai
`DispatchFailed`, mai rilascio del lease) fino al tentativo successivo. Dopo
`DISPATCH_MAX_ATTEMPTS` tentativi la richiesta fallisce definitivamente come
`DispatchFailed`.

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

## Identità e RBAC

Una singola **user-assigned managed identity** (`uami-api`) è condivisa da
`WipeIntake`, `GetStatus` e `JobMonitor`, perché sono la stessa Function App
(vincolo architetturale: nessuna identità separata per i "worker"). I ruoli
assegnati sono i minimi necessari e scoperti a livello di singola risorsa, non
di subscription o resource group:

| Ruolo | Scope | Perché |
|---|---|---|
| Storage Blob/Queue/Table Data Contributor (+ Blob Data Owner) | il solo storage account del deploy | host storage delle Function + tabella `wiperequests` (accesso a chiave condivisa disabilitato: solo Entra ID) |
| **Automation Job Operator** | il solo Automation Account del deploy | avviare job (`PUT .../jobs/{jobName}`), leggerne stato/output. Non concede la modifica dei runbook né l'accesso alle Automation Variables cifrate |

**Rischio residuo accettato**: poiché l'identità è condivisa, un'eventuale
compromissione del processo Function App concede *sia* lettura/scrittura sullo
stato di *ogni* richiesta di dismissione (inclusi seriali, IMEI, callback URL)
*sia* la possibilità di avviare/leggere qualunque job sui tre runbook
dell'Automation Account — non esiste, per design, un'identità "worker"
separata con un perimetro più stretto (es. una sola piattaforma). Questo è un
compromesso deliberato del PoC per mantenere una singola Function App
auditabile; per un ambiente di produzione con requisiti di isolamento più
stringenti, valutare il monitoraggio degli accessi di `uami-api` (Entra sign-in
logs / Automation job audit) e, se necessario, l'introduzione di un confine di
autorizzazione aggiuntivo (es. runbook separati per Automation Account, o
Conditional Access sulla risorsa).

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
private endpoint o zone DNS private. Storage continua a usare managed identity
e RBAC, ma è raggiungibile attraverso l'endpoint di rete pubblico:

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
`publicNetworkAccess=Disabled` per Storage.

Durante la migrazione, dopo la pubblicazione riuscita, lo script rimuove
automaticamente la Function App worker, la sua managed identity e il namespace
Service Bus con lo stesso prefisso/ambiente. Nei nuovi ambienti non trova
risorse e non esegue eliminazioni. **Prima di rimuovere un namespace Service
Bus legacy**, lo script verifica (per ogni coda e ogni sottoscrizione di ogni
topic) che il conteggio messaggi attivi e dead-letter sia zero; se trova un
backlog residuo, l'intero step di pulizia viene interrotto (`throw`) senza
eliminare nulla, per non perdere silenziosamente richieste di dismissione mai
processate dal vecchio percorso a coda.

Lo script provisiona l'infrastruttura, genera gli `handler.ps1` autosufficienti
(`build.ps1`) e pubblica la singola Function App.

Il deploy usa PowerShell 7.6 per la Function App e crea il Runtime
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

Il test E2E invia una richiesta con `dryRun=true`, accetta la risposta durevole
`Accepted` (o l'esito già avanzato dal dispatch inline), segue il `Location`
restituito dall'API e interroga lo stato fino a `Completed`:

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

Con `-Real`, dopo il completamento del job Automation il test continua a
interrogare lo stesso endpoint di status finché `intuneWipe.wipeState` non
diventa `done` (oppure il managed device viene rimosso), oppure finché
`-TimeoutSeconds` scade. Gli stati `pending` e `inProgress` non sono considerati
un completamento del wipe sul dispositivo.

Se chi esegue il test non ha accesso alle risorse Azure, usare l'entry point
diretto passando soltanto FQDN, Function key e seriale:

```powershell
./tests/Invoke-DispatchE2EDirect.ps1 -Fqdn attdisp-func-api-dev.azurewebsites.net -FunctionKey '<function-key>' -SerialNumber '<serial-number>'
```

Lo script non usa Azure CLI né Azure PowerShell. Aggiungere `-Real` solo per
impostare `dryRun=false` e attendere anche il completamento effettivo del wipe
esposto da Intune.

Per i dispositivi Windows, dopo che Graph accetta il wipe il runbook esegue
anche due nudges best-effort, come fallback per accelerare il check-in MDM:
attende 60 secondi e invia `syncDevice`, quindi attende altri 60 secondi e invia
`rebootNow`. Ogni nudge ritenta fino a tre volte sugli errori transitori
(`408`, `429`, `5xx`) e non trasforma in errore un wipe già accettato. I ritardi
si configurano con `SyncFallbackDelaySeconds` e
`RestartFallbackDelaySeconds` (`0` disabilita il relativo nudge); il numero di
tentativi si configura con `NudgeMaxAttempts` (1-5). In dry-run i nudges non
vengono eseguiti.

L'app registration Graph serve solo per le letture dell'intake:

- `DeviceManagementManagedDevices.Read.All` (application, con consenso admin)

I permessi di wipe restano sull'app registration usata dai runbook, non su questa.

> Nota: `func azure functionapp publish` reimposta la subscription di default di
> `az`. Ogni comando `az` successivo deve passare `--subscription` esplicito
> (`deploy.ps1` lo fa già).

### Connettività privata

Come per il PoC mock, la subscription può applicare una policy che forza
`publicNetworkAccess=Disabled` sullo storage. Il template crea quindi
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
├── build.ps1                 genera handler.ps1 autosufficienti con function inline
├── shared/Modules/           AT.Common, AT.Graph, AT.State,
│                             AT.Automation, AT.Dispatch
├── api/                      WipeIntake (POST), GetStatus (GET), JobMonitor (timer)
├── runbooks/                 i tre runbook di piattaforma corretti
├── infra/main.bicep          infrastruttura completa
├── infra/deploy.ps1          provisioning + publish
└── samples/                  payload di esempio
```

Ogni Function mantiene la logica del trigger in `source.ps1`. `build.ps1` genera
il relativo `handler.ps1`, copiando direttamente nel file tutte le function e le
inizializzazioni richieste da `shared/Modules`. Il risultato non usa here-string,
`New-Module`, `Export-ModuleMember` o import esterni: il cliente può leggere e
cercare il codice come un unico script PowerShell. Le modifiche continuano ad
avere un'unica sorgente nei PSM1; non modificare direttamente gli `handler.ps1`
generati. Il deploy verifica la struttura flat e che i soli `source.ps1` siano
esclusi dal pacchetto.
