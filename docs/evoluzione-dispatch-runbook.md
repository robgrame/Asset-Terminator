# Evoluzione della soluzione — dispatch asincrono verso runbook per piattaforma

> Proposta di evoluzione del PoC `poc-powershell-mock` da **function sincrona che esegue il
> wipe** a **pipeline event-driven**: la Function di intake valida e instrada la richiesta su
> **Azure Service Bus**, un **handler di backend** analizza il messaggio ed esegue il
> **dispatch** verso il **runbook Azure Automation specifico per piattaforma** già realizzato
> dal cliente.

Indice:

1. [Perché evolvere](#1-perché-evolvere)
2. [Analisi as-is dei runbook esistenti](#2-analisi-as-is-dei-runbook-esistenti)
3. [Architettura target](#3-architettura-target)
4. [Contratto di messaggio](#4-contratto-di-messaggio)
5. [Meccanismo di dispatch verso i runbook](#5-meccanismo-di-dispatch-verso-i-runbook)
6. [Topologia Service Bus](#6-topologia-service-bus)
7. [State store, correlazione e idempotenza](#7-state-store-correlazione-e-idempotenza)
8. [Completamento asincrono e callback](#8-completamento-asincrono-e-callback)
9. [Gestione errori, retry e DLQ](#9-gestione-errori-retry-e-dlq)
10. [Sicurezza](#10-sicurezza)
11. [Infrastruttura](#11-infrastruttura)
12. [Gap dei runbook attuali da chiudere](#12-gap-dei-runbook-attuali-da-chiudere)
13. [Percorso di migrazione](#13-percorso-di-migrazione)

---

## 1. Perché evolvere

Il PoC attuale (`poc-powershell-mock`) espone una singola Function HTTP che, nella stessa
richiesta, risolve il device in Intune, cancella l'oggetto Autopilot ed esegue il wipe. Va
bene come dimostratore, ma non regge il processo reale descritto in
_"Automazione nel processo di gestione Asset"_:

| Limite attuale | Impatto sul processo ENEL |
| --- | --- |
| **Esecuzione sincrona** | Il runbook Apple attende ~15 minuti la propagazione della sync DEP; il runbook Windows attende 60 s tra Autopilot e wipe. Una chiamata HTTP da ServiceNow non può restare appesa così a lungo (timeout Functions 230 s su piano dedicato). |
| **Logica di piattaforma nel front-end** | Le tre piattaforme di enrollment (Autopilot, ABM, Samsung KME) hanno auth, API e flussi completamente diversi. Metterli tutti nella Function di intake la rende fragile e non testabile. |
| **Nessun disaccoppiamento** | Un'indisponibilità di Knox o ABM fa fallire la richiesta di ServiceNow invece di essere ritentata. |
| **Nessun riuso degli asset del cliente** | Il cliente ha **già** tre runbook Azure Automation collaudati, con credenziali e certificati già configurati nell'Automation Account. Riscriverli nella Function è spreco e rischio. |
| **Nessuna evidenza persistente** | Il processo richiede di registrare in ServiceNow **l'esito**, non la sola schedulazione. Serve uno stato durevole e un polling nel tempo. |
| **Nessun controllo di concorrenza** | Due richieste sullo stesso seriale possono sovrapporsi. |

L'evoluzione proposta risolve tutti questi punti **senza riscrivere i runbook**: li promuove a
_execution backend_ della soluzione.

---

## 2. Analisi as-is dei runbook esistenti

### 2.1 Windows — `Windows_Disposal_Device.ps1`

| Aspetto | Dettaglio |
| --- | --- |
| Input | `-SerialNumbers` (CSV) oppure `WebhookData.RequestBody` con `serialNumbers` \| `serialNumber` \| `serial` |
| Auth Graph | App registration + **certificato** (`ClientId`, `TenantId`, `Certificate_thumbprint` da Automation Variables) |
| Flusso | 1) ricerca Autopilot per seriale → DELETE · 2) attesa 60 s · 3) ricerca `managedDevices` per seriale → POST `/wipe` (`keepEnrollmentData=false`, `keepUserData=false`) |
| Output | Solo `Write-Warning` / `Write-Output` sullo stream del job. **Nessun oggetto strutturato.** |
| Difetti noti | `:IsNullOrWhiteSpace(...)` in 3 punti — sintassi non valida, deve essere `[string]::IsNullOrWhiteSpace(...)`. Blocca il ramo webhook. |

### 2.2 Apple — `APPLE_Device_Disposal.ps1`

| Aspetto | Dettaglio |
| --- | --- |
| Input | `-SerialNumbers`, `-MdmServerId`, oppure `WebhookData` con `serialNumbers`/`serialNumber`/`serial` + `mdmServerId` |
| Auth ABM | OAuth 2.0 client-credentials con **JWT client assertion ES256** (`ABM-ClientId`, `ABM-KeyId`, `ABM-PrivateKey` EC P-256 PEM) |
| Auth Graph | App registration + certificato (come Windows) |
| Flusso | 1) token ABM · 2) GET `/v1/mdmServers` · 3) POST `/v1/orgDeviceActivities` con `activityType=UNASSIGN_DEVICES` · 4) polling activity · 5) sync di **tutti** i DEP token Intune · 6) **attesa 15 minuti** · 7) wipe Intune |
| Difetti noti | L'attesa di 15 min è in-band nel job. Il sync viene lanciato su **tutti** i token DEP, non solo su quello pertinente. Nessun output strutturato. |
| Variante | `ABM-OAuth2-unassignonly.ps1` esegue il solo unassign senza wipe — utile per lo scenario **Vendita**. |

### 2.3 Android — `ITA_SAMSUNG_KME_Device_Disposal.ps1`

| Aspetto | Dettaglio |
| --- | --- |
| Input | **Solo** `WebhookData` con `Serial` (singolo) o `Serials` (array). Non accetta parametri diretti. |
| Auth Knox | Knox Cloud Authentication, **JWT RS512** con chiave RSA (`KME-ClientIdentifier`, `KME-KeysJson`, `KME-CustomerId`) |
| Auth Graph | App registration + certificato |
| Flusso | 1) token Knox · 2) POST `/kcs/v1/kme/devices/delete` · 3) ricerca Intune per **IMEI** (15 cifre) o seriale · 4) wipe |
| Difetti noti | Non gestisce Google Zero-Touch (previsto dal processo). Fallisce se invocato senza webhook. Nessun output strutturato. |

### 2.4 Sintesi

* Tutti e tre condividono lo stesso **contratto d'ingresso di fatto**: uno o più seriali via
  webhook JSON. È la base su cui costruire il contratto unificato.
* Tutti e tre condividono la **stessa app registration Graph** (`ClientId` / `TenantId` /
  `Certificate_thumbprint`) → il PoC può continuare a usare la propria, ma in produzione
  conviene consolidare su una sola identità con least privilege.
* **Nessuno** restituisce un risultato strutturato: l'esito è ricavabile solo leggendo lo
  stream del job. Questo è il gap più importante da chiudere (§12).
* Il processo distingue **Ritiro** (solo wipe), **Vendita** (unenrollment + wipe) e
  **Smaltimento** (unenrollment + wipe + rimozione dai sistemi). I runbook attuali
  implementano solo lo scenario "unenrollment + wipe" → serve un parametro di **scenario**.

---

## 3. Architettura target

```
                    ┌──────────────────────────────────────────────────────────────┐
   ServiceNow       │                     Azure (RG dedicato)                       │
   ──────────►      │                                                               │
   POST /v1/wipe    │  ┌───────────────┐                                            │
                    │  │  WipeIntake   │  Function HTTP (authLevel=function)        │
   202 Accepted     │  │               │  • valida payload                          │
   { requestId }    │  │               │  • normalizza OS → platform                │
                    │  │               │  • guardrail rapidi (device in Intune,      │
                    │  │               │    cifratura) — opzionali/config-driven     │
                    │  │               │  • scrive stato = Accepted                  │
                    │  └───────┬───────┘  • pubblica messaggio                       │
                    │          │                                                     │
                    │          ▼                                                     │
                    │  ┌──────────────────────────────────────────┐                 │
                    │  │  Service Bus — topic `asset-disposal`     │                 │
                    │  │  sessioni abilitate (SessionId = serial)  │                 │
                    │  ├──────────────┬──────────────┬────────────┤                 │
                    │  │ sub-windows  │  sub-apple   │ sub-android│                 │
                    │  │ platform=    │  platform=   │ platform=  │                 │
                    │  │ 'Windows'    │  'Apple'     │ 'Android'  │                 │
                    │  └──────┬───────┴──────┬───────┴──────┬─────┘                 │
                    │         │              │              │                        │
                    │         ▼              ▼              ▼                        │
                    │  ┌──────────────────────────────────────────┐                 │
                    │  │        WipeDispatcher (Function)          │                 │
                    │  │  trigger Service Bus, una per subscription│                 │
                    │  │  • risolve l'handler di piattaforma        │                │
                    │  │  • mappa il contratto → parametri runbook  │                │
                    │  │  • avvia il job via ARM (Managed Identity) │                │
                    │  │  • salva jobName/jobId nello stato         │                │
                    │  └───────────────────┬──────────────────────┘                  │
                    │                      │ PUT .../jobs/{jobName}                   │
                    │                      ▼                                          │
                    │  ┌──────────────────────────────────────────┐                  │
                    │  │      Azure Automation Account             │                  │
                    │  │  ┌────────────┬────────────┬───────────┐ │                  │
                    │  │  │ Windows_   │ APPLE_     │ ITA_      │ │                  │
                    │  │  │ Disposal_  │ Device_    │ SAMSUNG_  │ │                  │
                    │  │  │ Device     │ Disposal   │ KME_...   │ │                  │
                    │  │  └────────────┴────────────┴───────────┘ │                  │
                    │  │  Variables: ClientId, TenantId,          │                  │
                    │  │  Certificate_thumbprint, ABM-*, KME-*    │                  │
                    │  └───────────────────┬──────────────────────┘                  │
                    │                      │                                          │
                    │         ┌────────────┴────────────┐                             │
                    │         ▼                         ▼                             │
                    │  ┌─────────────┐          ┌──────────────┐                     │
   callback         │  │  JobMonitor │◄─────────│ Table Storage│                     │
   ◄────────────────│  │ Timer 2 min │  stato   │  `wiperequests`                    │
   POST esito       │  │ poll job    │─────────►│ PK=requestId │                     │
                    │  │ + output    │          └──────┬───────┘                     │
                    │  └─────────────┘                 │                             │
                    │                                  ▼                             │
   GET /v1/wipe/    │                          ┌───────────────┐                     │
   status?requestId │◄─────────────────────────│   GetStatus   │                     │
                    │                          └───────────────┘                     │
                    │  Application Insights ◄── tutte le function                     │
                    └──────────────────────────────────────────────────────────────┘
```

### 3.1 Componenti

| Componente | Trigger | Responsabilità |
| --- | --- | --- |
| **WipeIntake** | HTTP `POST /api/v1/wipe` | Autenticazione chiamante, validazione schema, normalizzazione `operatingSystem` → `platform`, guardrail sincroni rapidi, creazione stato `Accepted`, pubblicazione su Service Bus. Risponde **202** con `requestId`. |
| **WipeDispatcher** | Service Bus (una function per subscription) | Analizza il messaggio, seleziona l'**handler di piattaforma**, mappa il contratto canonico nei parametri attesi dal runbook, avvia il job, persiste `automationJobName`, passa lo stato a `Dispatched`. |
| **JobMonitor** | Timer (ogni 2 min) | Recupera le richieste in stato `Dispatched`, interroga lo stato del job Automation, ne legge l'output, aggiorna lo stato a `Completed` / `Failed` / `PartiallyCompleted`, invia il callback a ServiceNow. |
| **GetStatus** | HTTP `GET /api/v1/wipe/status` | Espone lo stato corrente per `requestId` o per `serialNumber`, includendo le evidenze tecniche richieste dal processo. |

### 3.2 Principi mantenuti dalla soluzione principale

* **`requestId` come chiave di idempotenza end-to-end** — usato come `MessageId` Service Bus
  (duplicate detection), come `RowKey` nello state store e come `jobName` del job Automation.
* **Write-before-action** — lo stato viene scritto **prima** di pubblicare il messaggio e
  **prima** di avviare il job.
* **Continue-on-error** — un fallimento su una piattaforma non blocca le altre.
* **Config-driven** — mapping piattaforma → runbook, guardrail e timeout vengono da
  Application Settings, non dal codice.

---

## 4. Contratto di messaggio

### 4.1 Richiesta da ServiceNow (invariata + estesa)

```jsonc
{
  "requestId":       "CHG0012345",          // chiave di idempotenza, obbligatoria
  "scenario":        "Disposal",            // Retirement | Sale | Disposal | LostStolen
  "operatingSystem": "Windows",             // Windows | Mac | Mobile  (alias: win/macos/ios/android/…)
  "serialNumber":    "PF3ABCDE",            // identificativo primario
  "imei":            null,                  // alternativa per mobile
  "deviceName":      "FC1WRK001",           // opzionale, per il match secondario
  "managedDeviceId": null,                  // opzionale, se già noto a ServiceNow
  "ticketNumber":    "CHG0012345",
  "requestor":       "servicenow@enel.com",
  "userConfirmed":   true,                  // prerequisito di processo
  "callbackUrl":     "https://enel.service-now.com/api/x/asset_terminator/callback",
  "dryRun":          false
}
```

`scenario` è la novità che mappa i processi del documento:

| `scenario` | Unenrollment dalla piattaforma | Wipe Intune | Rimozione da AD/Entra |
| --- | --- | --- | --- |
| `Retirement` (Ritiro) | ✗ | ✓ | ✗ |
| `Sale` (Vendita) | ✓ | ✓ | ✗ |
| `Disposal` (Smaltimento) | ✓ | ✓ | ✓ |
| `LostStolen` | ✗ (o lock) | ✓ | da definire |

### 4.2 Messaggio Service Bus (contratto interno canonico)

```jsonc
// Body
{
  "schemaVersion":   "1.0",
  "requestId":       "CHG0012345",
  "correlationId":   "3f2c…",
  "platform":        "Windows",             // Windows | Apple | Android
  "scenario":        "Disposal",
  "device": {
    "serialNumber":    "PF3ABCDE",
    "imei":            null,
    "deviceName":      "FC1WRK001",
    "managedDeviceId": "fe143abc-…",        // risolto dall'intake quando possibile
    "operatingSystem": "Windows",
    "osVersion":       "10.0.22631.4460",
    "isEncrypted":     true
  },
  "options": {
    "removeFromEnrollmentPlatform": true,   // derivato da scenario
    "keepUserData":       false,
    "keepEnrollmentData": false,
    "dryRun":             false
  },
  "callbackUrl": "https://enel.service-now.com/api/…",
  "enqueuedAt":  "2026-07-29T09:12:33Z"
}
```

```jsonc
// Application properties  (usate dai filtri SQL delle subscription)
{
  "platform": "Windows",
  "scenario": "Disposal",
  "dryRun":   false
}
// MessageId  = requestId              → duplicate detection
// SessionId  = serialNumber           → ordinamento e mutua esclusione per device
// CorrelationId = correlationId
```

**Perché `platform` e non `operatingSystem`**: `operatingSystem` è il vocabolario di
ServiceNow (`Windows`/`Mac`/`Mobile`); `platform` è il vocabolario della **piattaforma di
enrollment** (`Windows`→Autopilot, `Apple`→ABM, `Android`→KME/Zero-Touch). La traduzione
avviene una sola volta, nell'intake:

| `operatingSystem` in ingresso | `platform` |
| --- | --- |
| `Windows`, `win` | `Windows` |
| `Mac`, `macOS`, `osx`, `iOS`, `iPadOS` | `Apple` |
| `Mobile`, `Android` | `Android` |

> Nota: `Mobile` è ambiguo (può essere iOS o Android). L'intake deve risolverlo
> interrogando `managedDevices.operatingSystem` in Intune prima di pubblicare, oppure
> ServiceNow deve inviare il valore specifico. **Raccomandazione: risoluzione in Intune**,
> perché il seriale è comunque già usato per il lookup ed è la fonte autorevole.

---

## 5. Meccanismo di dispatch verso i runbook

Tre opzioni valutate.

| | A — Webhook (as-is) | B — ARM REST `PUT jobs/{jobName}` | C — Hybrid Runbook Worker |
| --- | --- | --- | --- |
| Autenticazione | token nell'URL (segreto in chiaro) | **Managed Identity + RBAC** | come B |
| Idempotenza | nessuna | **`jobName` scelto dal client** (= `requestId`) | come B |
| Parametri | solo `WebhookData.RequestBody` | **parametri nominali tipizzati** | come B |
| Stato job | non correlabile facilmente | `GET jobs/{jobName}` | come B |
| Output job | non recuperabile | `GET jobs/{jobName}/output` | come B |
| Scadenza | il webhook scade (max 10 anni) e va rigenerato | nessuna | nessuna |
| Rete | endpoint pubblico Automation | ARM (`management.azure.com`) | worker on-prem |

**Raccomandazione: opzione B.** Il dispatcher usa la User-Assigned Managed Identity della
Function App con ruolo **Automation Job Operator** sull'Automation Account:

```http
PUT https://management.azure.com/subscriptions/{sub}/resourceGroups/{rg}
    /providers/Microsoft.Automation/automationAccounts/{aa}
    /jobs/{jobName}?api-version=2023-11-01
Content-Type: application/json

{
  "properties": {
    "runbook":    { "name": "Windows_Disposal_Device" },
    "parameters": { "SerialNumbers": "PF3ABCDE" },
    "runOn":      ""                       // "" = Azure sandbox; oppure nome Hybrid Worker Group
  }
}
```

* `jobName` = `requestId` (o `{requestId}-{tentativo}`) → **riavviare lo stesso messaggio non
  crea job duplicati**: ARM restituisce il job esistente.
* `parameters` sono `string`; oggetti complessi vanno serializzati in JSON.
* `runOn` permette di indirizzare in futuro un **Hybrid Worker** on-prem per la parte Active
  Directory prevista dal processo (§12), senza cambiare il dispatcher.

L'opzione A resta supportata come **fallback configurabile** (`DISPATCH_MODE=webhook`), utile
in fase di transizione o se l'Automation Account è in una subscription su cui non si ottiene
il ruolo RBAC.

### 5.1 Mapping handler → runbook

Tabella di routing esposta come Application Setting JSON (`RUNBOOK_MAP`), così da poter
aggiungere Google Zero-Touch senza rilasciare codice:

```jsonc
{
  "Windows": {
    "runbook":    "Windows_Disposal_Device",
    "parameters": { "SerialNumbers": "$.device.serialNumber" },
    "timeoutMinutes": 20
  },
  "Apple": {
    "runbook":    "APPLE_Device_Disposal",
    "parameters": {
      "SerialNumbers": "$.device.serialNumber",
      "MdmServerId":   "$.options.mdmServerId"
    },
    "timeoutMinutes": 45
  },
  "Android": {
    "runbook":    "ITA_SAMSUNG_KME_Device_Disposal",
    "parameters": { "Serial": "$.device.serialNumber" },
    "timeoutMinutes": 20
  }
}
```

> Il runbook Android accetta **solo** `WebhookData`: va adeguato ad accettare anche un
> parametro `-Serial`/`-Serials` diretto (§12). Fino ad allora, per Android il dispatcher usa
> automaticamente la modalità webhook.

---

## 6. Topologia Service Bus

**Scelta: un topic `asset-disposal` con una subscription per piattaforma**, invece di una
singola coda.

| Motivo | Beneficio |
| --- | --- |
| Le tre piattaforme hanno **profili di durata molto diversi** (Apple ~20 min, Windows ~2 min) | Ogni subscription ha `lockDuration`, `maxDeliveryCount` e concorrenza propri |
| Un'indisponibilità di Knox non deve rallentare Autopilot | **DLQ separate** per piattaforma |
| Aggiungere Google Zero-Touch = aggiungere una subscription | Estensibilità senza toccare il resto |
| Serve la possibilità di **sospendere** una piattaforma (§ sospensione del processo) | Basta disabilitare la subscription |

```
Topic: asset-disposal   (requiresDuplicateDetection=true, window 1h, sessions=true)
 ├─ sub-windows   filter: platform = 'Windows'   lockDuration PT5M   maxDelivery 5
 ├─ sub-apple     filter: platform = 'Apple'     lockDuration PT5M   maxDelivery 5
 ├─ sub-android   filter: platform = 'Android'   lockDuration PT5M   maxDelivery 5
 └─ sub-audit     filter: 1=1                    (opzionale: copia integrale per audit)
```

* **Sessioni con `SessionId = serialNumber`**: garantiscono che due richieste sullo stesso
  device non vengano elaborate in parallelo — requisito reale, perché il processo prevede sia
  Ritiro sia Smaltimento sullo stesso asset in momenti diversi.
* **Duplicate detection su `MessageId = requestId`**: un retry di ServiceNow non genera un
  secondo job.
* Il dispatcher **non attende** il completamento del runbook: avvia il job e completa il
  messaggio. Il lock di 5 minuti copre ampiamente la sola chiamata ARM.

---

## 7. State store, correlazione e idempotenza

Per il PoC: **Azure Table Storage** (stesso storage account della Function App, costo
trascurabile, nessun servizio aggiuntivo). Per la produzione: Azure SQL, come già previsto da
`AssetTerminator.Infrastructure`.

Tabella `wiperequests`:

| Campo | Esempio | Note |
| --- | --- | --- |
| `PartitionKey` | `Windows` | la piattaforma → query efficienti per il JobMonitor |
| `RowKey` | `CHG0012345` | = `requestId`, chiave di idempotenza |
| `correlationId` | `3f2c…` | propagato in tutti i log |
| `status` | `Dispatched` | vedi macchina a stati |
| `scenario` | `Disposal` | |
| `serialNumber` / `imei` / `deviceName` / `managedDeviceId` | | evidenze richieste dal processo |
| `automationJobName` | `CHG0012345` | usato per il polling |
| `automationJobId` | GUID ARM | |
| `dispatchedAt` / `completedAt` | ISO 8601 | timestamp di evidenza |
| `attempts` | `1` | |
| `resultJson` | `{...}` | output strutturato del runbook |
| `errorMessage` | | |
| `callbackStatus` | `Sent` / `Failed` | |

### 7.1 Macchina a stati

```
Accepted ──► Queued ──► Dispatched ──► Running ──┬─► Completed
    │           │            │                    ├─► PartiallyCompleted
    │           │            │                    └─► Failed
    │           │            └─► DispatchFailed
    │           └─► Rejected (guardrail non superato → task manuale in ServiceNow)
    └─► Rejected (validazione)
```

`PartiallyCompleted` copre il caso reale: unenrollment riuscito ma wipe fallito (o viceversa)
— situazione che i runbook attuali producono spesso e che il processo deve saper distinguere
per aprire il task manuale corretto.

---

## 8. Completamento asincrono e callback

`JobMonitor` (timer, default ogni 2 minuti):

1. Query Table Storage: `status in (Dispatched, Running)`.
2. Per ciascuna: `GET /automationAccounts/{aa}/jobs/{jobName}?api-version=2023-11-01`
   → `properties.status` ∈ `New`, `Activating`, `Running`, `Completed`, `Failed`,
   `Stopped`, `Suspended`.
3. Se terminale: `GET .../jobs/{jobName}/output` per recuperare lo stream.
4. Parsing dell'esito (§12: i runbook devono emettere una riga
   `##RESULT## {json}` per rendere questo passo deterministico).
5. Aggiornamento stato + `completedAt` + `resultJson`.
6. **Callback a ServiceNow** su `callbackUrl` con retry esponenziale; se fallisce
   definitivamente, il messaggio finisce in una coda `callback-deadletter` (stesso pattern
   già presente in `src-powershell/infra/modules/servicebus.bicep`).
7. Timeout: superato `timeoutMinutes` della piattaforma, stato → `Failed` con
   `errorMessage = "Runbook job timeout"`.

Il payload del callback contiene le **evidenze tecniche** richieste dal documento di
processo: data/ora invio comando, Device ID, seriale/IMEI, stato dell'azione, esito Intune,
esito rimozione dalla piattaforma di enrollment.

> **Verifica post-wipe.** Il documento chiede un controllo periodico (es. ogni 24 h) che il
> device non sia più presente in Intune. Si realizza con un secondo timer
> (`PostWipeReconciler`) che rilegge le richieste in stato `Completed` da meno di N giorni e
> verifica l'assenza dell'oggetto in Intune / Autopilot / ABM / KME, riaprendo il flusso se
> il device ricompare. Fuori dallo scope minimo del PoC, ma il modello dati lo supporta già.

---

## 9. Gestione errori, retry e DLQ

| Livello | Meccanismo |
| --- | --- |
| Intake | Errori di validazione → **400** immediato, nessun messaggio pubblicato. Guardrail non superato → **422** + stato `Rejected` (ServiceNow apre il task manuale). |
| Pubblicazione Service Bus | Retry SDK; se fallisce, **500** e nessuno stato `Queued` → ServiceNow ritenta con lo stesso `requestId` (idempotente). |
| Dispatcher | Errore transitorio ARM (429/5xx) → eccezione → Service Bus ritenta fino a `maxDeliveryCount=5` con backoff. Errore permanente (runbook inesistente, RBAC mancante) → stato `DispatchFailed` + completamento del messaggio + dead-letter esplicito con `DeadLetterReason`. |
| Runbook | Il job fallisce → `JobMonitor` marca `Failed` e invia il callback: ServiceNow apre il task manuale con le evidenze già raccolte. |
| DLQ | Una function `DeadLetterHandler` per subscription legge la DLQ, registra l'evidenza e notifica. Nessun messaggio va perso silenziosamente. |

---

## 10. Sicurezza

* **Nessun segreto nel codice né negli URL.** I webhook attuali contengono il token in query
  string ed erano committati negli script client (`ITA_Start-SamsungKME_Disposal.ps1`,
  `SendSerialtoAppleDisposal.ps1`): vanno **revocati e rigenerati**, e comunque sostituiti
  dall'opzione B.
* **Managed Identity** per: Service Bus (`Azure Service Bus Data Sender` sull'intake,
  `Data Receiver` sul dispatcher), Automation (`Automation Job Operator`), Table Storage
  (`Storage Table Data Contributor`), Graph (Federated Identity Credential o app
  registration con certificato).
* **Credenziali di piattaforma** (ABM, Knox, certificato Graph) **restano nell'Automation
  Account** come Automation Variables cifrate / certificati: la Function non le vede mai.
  È un vantaggio di sicurezza sostanziale del modello proposto.
* **Autenticazione del chiamante**: per il PoG la Function Key è sufficiente; in produzione
  Entra ID (App Role dedicato a ServiceNow) o mTLS, come da `docs/permissions.md`.
* **Least privilege Graph**: l'intake ha bisogno solo di
  `DeviceManagementManagedDevices.Read.All` (lookup + guardrail cifratura). I permessi
  privilegiati (`…PrivilegedOperations.All`, `DeviceManagementServiceConfig.ReadWrite.All`)
  restano sull'app registration usata dai runbook. **Separazione dei privilegi tra chi
  accetta la richiesta e chi la esegue.**

---

## 11. Infrastruttura

Delta rispetto a `poc-powershell-mock/infra/main.bicep`:

| Risorsa | Note |
| --- | --- |
| **Service Bus namespace** (Standard — serve per i topic) | `disableLocalAuth: true`, sessioni abilitate |
| **Topic** `asset-disposal` + 3 subscription con filtro SQL | duplicate detection 1 h |
| **Automation Account** | con identità gestita; i runbook vengono importati e pubblicati |
| **Table** `wiperequests` nello storage esistente | |
| **Role assignment** UAMI → `Azure Service Bus Data Sender` / `Data Receiver` | |
| **Role assignment** UAMI → `Automation Job Operator` sull'Automation Account | |
| **Role assignment** UAMI → `Storage Table Data Contributor` | già presente nel mock |
| **Private endpoint** per Service Bus | necessario se la policy di tenant lo impone, come già accaduto per lo storage nel deploy corrente |

Il resto (piano B1 Linux, Function App PowerShell 7.4, Application Insights, VNet +
private endpoint verso lo storage) è già in essere e non cambia.

---

## 12. Gap dei runbook attuali da chiudere

Interventi **minimi e non invasivi** sui runbook del cliente, necessari per renderli
pilotabili dal dispatcher:

| # | Gap | Intervento | Priorità |
| --- | --- | --- | --- |
| 1 | `Windows_Disposal_Device.ps1` usa `:IsNullOrWhiteSpace(...)` (3 occorrenze) — sintassi non valida | correggere in `[string]::IsNullOrWhiteSpace(...)` | **Bloccante** |
| 2 | Nessun output strutturato | emettere in coda al job una riga `##RESULT## {json}` con `{requestId, platform, enrollmentRemoved, wipeIssued, managedDeviceId, deviceName, serial, errors[]}` | **Alta** |
| 3 | Il runbook Android accetta solo `WebhookData` | aggiungere i parametri `-Serial` / `-Serials` come Windows/Apple | **Alta** |
| 4 | Nessun `requestId` in ingresso | aggiungere `-RequestId` e includerlo in ogni riga di log e nel `##RESULT##` — indispensabile per la correlazione e l'audit | **Alta** |
| 5 | Nessuna nozione di **scenario** | aggiungere `-Scenario` (`Retirement`/`Sale`/`Disposal`): con `Retirement` si salta l'unenrollment | **Alta** |
| 6 | Apple attende 15 min in-band | spezzare in `APPLE_Unassign` + `APPLE_Wipe`, orchestrati dal dispatcher/JobMonitor; oppure ridurre l'attesa verificando attivamente lo stato del device in Intune | Media |
| 7 | Apple sincronizza **tutti** i token DEP | sincronizzare il solo token pertinente | Media |
| 8 | `keepUserData` / `keepEnrollmentData` cablati a `$false` | esporli come parametri | Media |
| 9 | Google Zero-Touch non coperto | nuovo runbook + nuova voce in `RUNBOOK_MAP` | Media |
| 10 | Nessuna rimozione da AD / Entra ID | nuovo runbook su **Hybrid Worker** (`runOn`) per il computer account AD | Media |
| 11 | Log via `Write-Warning` | passare a `Write-Output` strutturato; opzionale: invio diretto ad Application Insights per una vista unica | Bassa |

> I punti 2 e 4 sono i più importanti: senza di essi il `JobMonitor` non può produrre le
> **evidenze di esito** che il processo richiede a ServiceNow, e si resta a "registrare la
> sola schedulazione" — esattamente ciò che il documento vieta.

---

## 13. Percorso di migrazione

| Fase | Contenuto | Esito |
| --- | --- | --- |
| **0 — as-is** | PoC sincrono già deployato (`attmock-func-dev`) | baseline dimostrabile |
| **1 — asincronia** | Aggiunta Service Bus + `WipeIntake` (202) + `WipeDispatcher` + `JobMonitor` + Table state. Il dispatcher continua a fare il wipe **in-process** come oggi. | Contratto asincrono validato con ServiceNow senza dipendere dai runbook |
| **2 — dispatch ai runbook** | Import dei 3 runbook nell'Automation Account, `DISPATCH_MODE=arm`, `RUNBOOK_MAP` popolata. Gap 1–5 chiusi. | I runbook del cliente diventano l'execution backend |
| **3 — scenari e guardrail** | `scenario`, guardrail cifratura/conferma utente, `Rejected` → task manuale ServiceNow | Allineamento al documento di processo |
| **4 — consolidamento** | Post-wipe reconciler, DLQ handler, rimozione AD/Entra via Hybrid Worker, Zero-Touch | Copertura end-to-end |
| **5 — produzione** | Migrazione dello state store su Azure SQL, auth Entra ID al posto della Function Key, private endpoint Service Bus, riuso di `src/` .NET se richiesto | Go-live |

La fase 1 è **retro-compatibile**: `POST /api/v1/wipe` mantiene lo stesso path e lo stesso
body; cambia solo la risposta da `200` (esito) a `202` (`requestId` + `Location` verso
`/api/v1/wipe/status`). ServiceNow può adottare il polling su `GetStatus` prima ancora che il
callback sia implementato.
