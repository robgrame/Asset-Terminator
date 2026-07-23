# Asset-Terminator — PowerShell parity source (`src-powershell/`)

A **parallel, PowerShell-only** implementation of Asset-Terminator, built to reach
**feature parity** with the .NET solution in [`../src`](../src). It is an
independent source tree — the .NET solution stays intact and both are maintained
in parity (see [decision log](#decisions)).

> Driver: the client's team works in PowerShell, not C#/.NET. This tree removes
> the .NET build/runtime dependency while preserving the full behaviour:
> guarded Intune wipe, WORM hash-chained audit, SLA tiers, ServiceNow callbacks,
> RBAC override, async polling, Durable orchestration and the on-prem agent.

## Layout

```
src-powershell/
  modules/                       # shared modules (source of truth, synced into apps)
    AT.Common/                   # logging, tokens (MI), resilient Graph REST, retry
    AT.Contracts/                # enums + DecommissionRequest/response shapes
    AT.Core/                     # state model, request validation, target resolution
    AT.Infrastructure/           # SQL state store, WORM audit, SLA, Service Bus, callbacks, KV, observability
    AT.Guardrails/               # config-driven guardrail engine + override hook
    AT.Providers.Intune/         # wipe/retire/delete/Autopilot            (done)
    AT.Providers.EntraId/        # device lookup + delete                  (done)
    AT.Providers.ActiveDirectory/# AD computer delete (ADSI/LDAP)          (done)
    AT.Providers.ConfigMgr/      # SCCM AdminService REST                  (done)
    AT.Providers.DeviceActions/  # license step-down + BIOS password removal (done)
  api/                           # HTTP Function App: intake/status/history/override (done)
  orchestrator/                  # Durable Function App: orchestrator + activities + polling (done)
  onprem-agent/                  # scheduled-task PowerShell agent (pull from Service Bus) (done)
  infra/                         # Bicep (PowerShell Flex runtime) + sql/schema.sql
  tests/                         # Pester suites
  run-tests.ps1                  # PSScriptAnalyzer + Pester (parity with dotnet build/test)
```

## Build & test

```powershell
cd src-powershell
./run-tests.ps1            # lint (PSScriptAnalyzer) + full Pester suite
./run-tests.ps1 -SkipLint  # tests only
```

Prerequisites: PowerShell 7.4+, Pester 5+, PSScriptAnalyzer. The Functions apps
additionally require Azure Functions Core Tools v4 and the Az REST access used by
the shared modules (Managed Identity in Azure, `az` CLI locally).

## Parity mapping (PowerShell ↔ .NET)

| PowerShell module / app                 | .NET project / type |
|---|---|
| `AT.Common`                             | Infrastructure `GraphClientFactory`, `Resilience`, logging |
| `AT.Contracts`                          | `AssetTerminator.Contracts` (enums, `DecommissionRequest`, responses) |
| `AT.Core`                               | `AssetTerminator.Core` + `IntakeService` validation/target resolution |
| `AT.Infrastructure/Sla.psm1`            | `Infrastructure.Sla.SlaCalculator` + `SlaOptions` |
| `AT.Infrastructure/Audit.psm1`          | `Infrastructure.Audit.BlobAuditWriter` (WORM hash-chain) |
| `AT.Infrastructure/SqlStateStore.psm1`  | `Infrastructure.Data.StateStore` + `AssetTerminatorDbContext` (`GetOrCreateAsync`) |
| `AT.Infrastructure/Messaging.psm1`      | `Infrastructure.Messaging` (Service Bus send + workflow start + on-prem routing) |
| `AT.Infrastructure/Callbacks.psm1`      | `Infrastructure.Callbacks.ServiceNowCallbackSender` (retry/backoff/eventId) |
| `AT.Infrastructure/Secrets.psm1`        | `Infrastructure.Secrets` (Key Vault) |
| `AT.Infrastructure/Observability.psm1`  | `Infrastructure.Observability` (Log Analytics) |
| `infra/sql/schema.sql`                  | `Infrastructure.Data.AssetTerminatorDbContext` (EF model) |
| `AT.Guardrails`                         | `AssetTerminator.Guardrails` (`IWipeGuardrail`, `GuardrailEngine`) |
| `AT.Providers.Intune`                   | `AssetTerminator.Providers.Intune` (wipe/retire/delete/Autopilot) |
| `AT.Providers.EntraId`                  | `AssetTerminator.Providers.EntraId` (device delete) |
| `AT.Providers.ActiveDirectory`          | `AssetTerminator.Providers.ActiveDirectory` (AD computer delete) |
| `AT.Providers.ConfigMgr`                | `AssetTerminator.Providers.ConfigMgr` (SCCM AdminService) |
| `AT.Providers.DeviceActions`            | `AssetTerminator.Providers.DeviceActions` (license/BIOS) |
| `api/`                                  | `AssetTerminator.Api` (intake/status/history/override functions) |
| `orchestrator/`                         | `AssetTerminator.Orchestrator` (Durable orchestrator + activities + polling timer) |
| `onprem-agent/Modules/AT.Agent`         | `AssetTerminator.OnPremAgent.Worker` (`ProcessAsync` dispatch) |
| `onprem-agent/Modules/AT.ServiceBusReceiver` | Service Bus data-plane receive (peek-lock/complete/abandon) |
| `infra/`                                | `../infra` (Bicep) — `functionapp.bicep` swaps runtime to `powershell/7.4` |

## Design notes

- **No compile-time types** — parity is protected by Pester + PSScriptAnalyzer.
- **State store is Azure SQL** — schema is hand-managed DDL (`infra/sql/schema.sql`),
  no EF migrations.
- **Audit hash chain is chain-internal** — the SHA-256 chain makes the PowerShell
  audit self-verifying (`Test-AuditChain`); it is not required to byte-match the
  .NET chain, since the two are separate deployments.
- **Guardrails match the .NET semantics, defaulting to Mandatory/fail-closed** —
  `Encryption` is device-type aware (Windows accepts an escrowed BitLocker recovery
  key; unknown state fails closed), `Inactivity` blocks a device that is *not* inactive
  past the threshold (unknown last activity fails closed, default 30 days), and
  `CriticalGroup` blocks on any Entra `groupMemberships` match against `BlockedGroups`.
  As a deliberate, safe **superset**, the PowerShell `CriticalGroup` *additionally*
  blocks on the Intune `deviceCategoryDisplayName` (which the enricher already
  populates) using the same blocked set — it only ever blocks more, never less, than
  the .NET rule. Like .NET, the enricher does not yet populate `hasRecoveryKeyEscrowed`
  or `groupMemberships` in production (see the TODO in `Get-EnrichedDeviceContext`).
- **Durable orchestrator stays thin** — all real work lives in activity functions.
- **On-prem agent** runs as a **scheduled task (SYSTEM)** that pulls from Service Bus.

## Deploy

```powershell
cd src-powershell/infra
./deploy.ps1 -ResourceGroup <rg> -Location westeurope `
    -SqlAdminGroupName <entra-group> -SqlAdminGroupObjectId <group-object-id>
# infra-only (skip func publish):
./deploy.ps1 -ResourceGroup <rg> -SqlAdminGroupName <g> -SqlAdminGroupObjectId <id> -SkipPublish
```

`deploy.ps1` runs `az deployment group what-if` then `create` on `main.bicep`, syncs the
shared `modules/` into `api/Modules/` and `orchestrator/Modules/`, and publishes both
Function Apps with `func azure functionapp publish --powershell`. Steps that **cannot** be
expressed in Bicep are printed at the end and must be done manually (see below).

### Post-deploy manual steps

1. **SQL schema** — apply `infra/sql/schema.sql` against the database with an Entra token
   (no EF migration): `Invoke-Sqlcmd -AccessToken (az account get-access-token --resource https://database.windows.net/ --query accessToken -o tsv) ...`.
2. **SQL contained users** — create one per UAMI (API / orchestrator / on-prem) and grant
   `db_datareader` + `db_datawriter` (template in the comment block at the end of `deploy.ps1`).
3. **Graph app roles** — grant to the orchestrator UAMI service principal and admin-consent.
4. **On-prem agent** — install with `onprem-agent/Install-OnPremAgent.ps1` (SYSTEM scheduled task).

## Permissions

| Identity | Grants |
|---|---|
| API UAMI | SQL `db_datareader`/`db_datawriter`; Key Vault secret read |
| Orchestrator UAMI | SQL `db_datareader`/`db_datawriter`; Service Bus send; audit blob write; **Graph app roles** below |
| On-prem UAMI / task identity | SQL `db_datareader`/`db_datawriter`; Service Bus receive; on-device rights for AD/SCCM/OEM tools |

Microsoft Graph **application** permissions for the orchestrator UAMI (parity with `../infra/deploy.ps1`):

- `DeviceManagementManagedDevices.PrivilegedOperations.All` — wipe
- `DeviceManagementManagedDevices.ReadWrite.All` — retire / managed-device delete
- `Device.ReadWrite.All` — Entra device delete
- `DeviceManagementServiceConfig.ReadWrite.All` — Windows Autopilot delete

> Managed-Identity token caching: after assigning new Graph app roles to a UAMI the `roles`
> claim can take up to ~24h to appear. Force a fresh token by removing and re-assigning the
> UAMI to the Function App (`az functionapp identity remove` → `identity assign`) + restart.

<a name="decisions"></a>
## Decisions (confirmed)

1. Location: `src-powershell/` at repo root.
2. State store: **Azure SQL** (parity), DDL-managed.
3. Both the C# and PowerShell sources are **maintained in parity** — functional
   changes must be applied to both.
4. On-prem agent hosting: **scheduled task (SYSTEM)**.

## Status

| Phase | Area | Status |
|---|---|---|
| P0 | Scaffolding, `AT.Common`, tooling | ✅ done |
| P1 | Contracts + Core (validation, target resolution) | ✅ done |
| P2 | Infrastructure — SQL state store, WORM audit, SLA, SB, callbacks, KV, observability | ✅ done |
| P3 | Guardrail engine + override hook | ✅ done |
| P4 | Cloud providers (Intune/Entra) | ✅ done |
| P5 | API Function App | ✅ done |
| P6 | Durable orchestrator | ✅ done |
| P7 | Async polling + SLA state + callbacks | ✅ done |
| P8 | On-prem agent (AD/SCCM/DeviceActions) | ✅ done |
| P9 | IaC (Bicep, PowerShell Flex runtime) | ✅ done |
| P10 | Pester parity suite | ✅ 181 tests passing |
| P11 | Docs | ✅ this README |

## Test parity checklist (.NET xUnit ↔ PowerShell Pester)

Every behaviour asserted by the four .NET test projects has an equivalent Pester assertion.

| .NET test | PowerShell coverage |
|---|---|
| `IntakeServiceTests.MissingRequestId_IsRejected` | `AT.Core` — *requires requestId* |
| `IntakeServiceTests.MissingDeviceNameAndSerial_IsRejected` | `AT.Core` — *requires deviceName or serialNumber* |
| `IntakeServiceTests.ValidNewRequest_StartsWorkflowOnce` | `AT.Infrastructure` — *creates a new request once and reports Created=$true* |
| `IntakeServiceTests.DuplicateRequest_IsIdempotent…` | `AT.Infrastructure` — *is idempotent for a duplicate request and reports Created=$false* |
| `IntakeServiceTests.WindowsTerminateWipe_AutoInjectsPreWipeActions` | `AT.Core` — *auto-injects pre-wipe actions for a Windows Terminate wipe* |
| `IntakeServiceTests.WindowsTerminateWipe_WithoutSerial_DoesNotInjectAutopilot` | `AT.Core` — *does not inject Autopilot without a serialNumber* |
| `IntakeServiceTests.RetireDisposition_InjectsRetireAndOmitsWipe` | `AT.Core` — *adds Retire and removes Wipe for a Retire disposition* |
| `IntakeServiceTests.RetireDisposition_WithWipeAction_IsRejected` | `AT.Core` — *rejects Retire disposition with Wipe action* |
| `IntakeServiceTests.PreWipeDisabled_DoesNotInjectPreventiveActions` | `AT.Core` — *honors disabled pre-wipe flags* |
| `GuardrailTests` encryption matrix (`*Encrypted*`/`*RecoveryKey*`/`*FileVault*`/`*Ios*`/`*Null*`) | `AT.Guardrails` — *Encryption guardrail (parity with EncryptionGuardrail.cs)* Describe (Windows encrypted/escrow/unencrypted, macOS FileVault-off, iOS platform-enforced, null fails closed) |
| `GuardrailTests` inactivity (`*Inactive*`/`*Recently*`/`*Null*`) | `AT.Guardrails` — *Inactivity guardrail (parity with InactivityGuardrail.cs)* Describe (recently-active blocks, beyond-threshold passes, null fails closed) |
| `GuardrailTests` critical group (`*BlockedGroup*`/`*NotIn*`) | `AT.Guardrails` — *CriticalGroup guardrail (parity with CriticalGroupGuardrail.cs)* Describe (in-blocked-group blocks, not-in passes) |
| `GuardrailTests.MandatoryGuardrailFailureMakesEvaluationNotAllowed` | `AT.Guardrails` — *blocks the wipe when encryption (mandatory) fails* |
| `GuardrailTests.NonMandatoryGuardrailFailureStillAllowsEvaluation` | `AT.Guardrails` — *does not block on a warning-mode failure* |
| `GuardrailTests.OverriddenGuardrailFailureIsConvertedToPassingWarning` | `AT.Guardrails` — *bypasses an overridable mandatory failure when overridden* |
| `GuardrailTests.ThrowingGuardrailFailsClosed` | `AT.Guardrails` — *fails closed when a guardrail throws* |
| `GuardrailTests.DisabledGuardrailIsSkipped` | `AT.Guardrails` — *skips a disabled guardrail* |
| `OverallStateTests.*` (5) | `AT.Orchestrator` — *Get-OverallState* Describe (Completed/InProgress/PartiallyCompleted/Failed) |
| `ReconciliationServiceTests.PastDue_TimesOut…` | `AT.Orchestrator` — *Get-PreWipeStatus flags a passed deadline* + reconcile give-up |
| `ReconciliationServiceTests.WipeCompleted_MarksActionSuccess` / `RetireCompleted…` | `AT.Providers` — *Get-IntuneWipeStatus reports Success…* + `AT.Orchestrator` *reconciles … as terminal success* |
| `ReconciliationServiceTests.TransientFailure_RetriesWithBackoff` | `AT.Orchestrator` — *retries a transient failure with backoff below the cap* |
| `ReconciliationServiceTests.MaxRetriesExceeded_MarksFailed` | `AT.Orchestrator` — *fails once max retries is reached* |
| `ReconciliationServiceTests.PermanentFailure_MarksFailedImmediately` | `AT.Orchestrator` — *marks a hard failure as terminal* |
| `ProviderRegistrationTests.*` (6) | `AT.Orchestrator` *Invoke-CloudDelete/Invoke-ProviderStatus dispatch* + `AT.Agent` *Invoke-AgentProvider dispatch* (target→provider routing is the PS equivalent of DI registration) |

## Two-source alignment checklist (C# ↔ PowerShell)

Both sources are maintained in parity (decision 3). When a functional change is made to
one tree, apply it to the other in the same PR and tick this list:

- [ ] **Contract/enum change** → update `AT.Contracts` **and** `AssetTerminator.Contracts`.
- [ ] **Validation / target-resolution / pre-wipe injection** → `AT.Core` **and** `IntakeService`.
- [ ] **Guardrail rule or override semantics** → `AT.Guardrails` **and** `AssetTerminator.Guardrails`.
- [ ] **Provider behaviour** (Intune/Entra/AD/ConfigMgr/DeviceActions) → matching `AT.Providers.*` **and** `AssetTerminator.Providers.*`.
- [ ] **Orchestrator/activity/polling logic** → `orchestrator/` **and** `AssetTerminator.Orchestrator`.
- [ ] **SQL schema** → `infra/sql/schema.sql` **and** the EF model (`AssetTerminatorDbContext`); keep column names/types identical.
- [ ] **App settings / Bicep** → PS `infra/functionapp.bicep` (flat env vars) **and** .NET `infra/modules/functionapp.bicep` (hierarchical `AssetTerminator__*`).
- [ ] **Tests** → add/adjust a Pester assertion **and** the xUnit fact; keep the *Test parity checklist* above current.
- [ ] Run `./run-tests.ps1` (PS) and `dotnet test` (.NET) — both green before merge.

The existing cloud-only [`../poc-powershell`](../poc-powershell) is the proven
starting point reused by the provider/app phases.
