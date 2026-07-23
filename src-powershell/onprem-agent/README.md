# On-prem agent (`onprem-agent/`)

PowerShell parity host for **`AssetTerminator.OnPremAgent`**. Runs inside the customer network
with line-of-sight to the Domain Controller and the ConfigMgr (SCCM) AdminService, draining the
on-prem Service Bus queue and executing the actions the cloud orchestrator cannot perform.

## What it does

Pulls `ActionDispatch` messages (`{ requestId, target }`) from the on-prem queue (peek-lock),
then for each `target`:

| Target                | Provider module                 | Action                                              |
| --------------------- | ------------------------------- | --------------------------------------------------- |
| `ActiveDirectory`     | `AT.Providers.ActiveDirectory`  | Delete the AD computer object (ADSI/LDAP)           |
| `ConfigMgr`           | `AT.Providers.ConfigMgr`        | Delete the device via the AdminService OData REST   |
| `LicenseRemoval`      | `AT.Providers.DeviceActions`    | Remove the Enterprise license (step-down to Pro)    |
| `BiosPasswordRemoval` | `AT.Providers.DeviceActions`    | Clear the BIOS/UEFI supervisor password (OEM tool)  |

Each action writes a **write-before / write-after** pair to the immutable WORM audit and updates
the sub-action status in the shared **Azure SQL** state store. Transient failures revert the
action to `InProgress` so Service Bus redelivery (and the cloud poller) retry; hard failures are
final. This mirrors `Worker.ProcessAsync` / `ApplyResult` exactly.

## Layout

```
onprem-agent/
  run-agent.ps1               # entry point: receive -> process -> complete/abandon loop
  Install-OnPremAgent.ps1     # registers the SYSTEM scheduled task
  agent.settings.psd1.example # config template (copy to agent.settings.psd1)
  Modules/
    AT.Agent/                 # dispatch core (parity with Worker)
    AT.ServiceBusReceiver/    # data-plane SB receive (peek-lock/complete/abandon) via REST
```

The shared `AT.*` modules under `src-powershell/modules/` are the source of truth; a deploy-time
sync copies them into `Modules/`. During local runs `run-agent.ps1` also falls back to the repo
`modules/` directory.

## Hosting: SYSTEM scheduled task

The agent is hosted as a **recurring SYSTEM scheduled task** (confirmed design decision), not a
long-lived service. Each launch drains the queue for a bounded window (`-MaxRuntimeSeconds`, ~5
min under the schedule interval) and then exits; the task re-launches on the next tick. This keeps
long-running device tools (DISM/OEM BIOS utilities) alive as SYSTEM child processes instead of
being killed at shell teardown.

```powershell
# 1. Configure
Copy-Item .\agent.settings.psd1.example .\agent.settings.psd1
#    edit ServiceBus.Namespace, ConfigMgr.AdminServiceBaseUrl, DeviceActions.*, Environment.*

# 2. Install (elevated)
.\Install-OnPremAgent.ps1 -IntervalMinutes 60

# 3. (optional) run once in the foreground for a smoke test
.\run-agent.ps1 -MaxRuntimeSeconds 120
```

## Authentication (passwordless)

- **Service Bus / SQL / Blob audit**: Entra token via Managed Identity (Azure Arc-enabled server)
  or the `az` CLI fallback; set `UAMI_CLIENT_ID` when multiple identities are assigned. A SAS token
  can be supplied in `ServiceBus.SasToken` instead.
- **ConfigMgr AdminService**: the task's Windows-integrated identity by default, or a
  DPAPI-protected credential file referenced by `ConfigMgr.CredentialXmlPath` (create it as the
  task account with `Get-Credential | Export-Clixml <path>`).

## Safety

`DryRun = $true` (default in the template) simulates every destructive action. Flip to `$false`
only after validating the AD search root, the AdminService URL and the DeviceActions command specs.
