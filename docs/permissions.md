# Asset-Terminator permission matrix

Asset-Terminator uses least-privilege, per-capability identities. Cloud actions are granted to user-assigned managed identities (UAMIs); on-premises actions are executed only by the self-hosted worker.

| Action | Minimum permission | Where it is granted | Notes |
| --- | --- | --- | --- |
| Intune managed device wipe / retire | Microsoft Graph application permission `DeviceManagementManagedDevices.PrivilegedOperations.All` | Orchestrator Intune UAMI service principal | Required for destructive privileged operations such as wipe and retire. Scope this UAMI only to the wipe capability. |
| Intune managed device read/delete | Microsoft Graph application permission `DeviceManagementManagedDevices.ReadWrite.All` | Orchestrator Intune UAMI service principal | Used to read and delete Intune managed device records after wipe policy allows it. |
| Entra device lookup/delete | Microsoft Graph application permission `Device.ReadWrite.All` plus directory read for lookup | Orchestrator Entra UAMI service principal | Grants device object update/delete. Directory read is used only to resolve the target object. |
| Encryption guardrail signal | Microsoft Graph application permissions `DeviceManagementManagedDevices.Read.All` and `BitlockerKey.Read.All` | Guardrail/read-only UAMI service principal | Read-only. Used to confirm Intune encryption state and BitLocker recovery key escrow before wipe. FileVault checks should use the equivalent read-only MDM inventory signal. |
| AD computer delete | Delegated "Delete computer objects" on the target OU | On-prem service account or gMSA used by the worker service | No Graph permission. Limit delegation to decommissionable computer OUs only. |
| SCCM / ConfigMgr device delete | ConfigMgr AdminService access using an account with the `Delete` right on the Device collection, or a tightly scoped Full Administrator role | On-prem worker Windows-integrated authentication account | Prefer collection-scoped RBAC. Use Windows-integrated authentication to the AdminService. |
| Audit blob write | Azure RBAC `Storage Blob Data Contributor` | Audit writer UAMI | Writes immutable audit records to Blob Storage with WORM time-based retention. |
| Service Bus enqueue/dequeue | Azure RBAC `Azure Service Bus Data Sender` and/or `Azure Service Bus Data Receiver` | API/orchestrator sender UAMI and on-prem worker receiver identity as appropriate | API/orchestrator sends on-prem work; worker receives and reports results. Split sender and receiver identities where possible. |
| Key Vault secret read | Azure RBAC `Key Vault Secrets User` | API UAMI and other components that must read secrets | Used for ServiceNow API key, callback secret material, and other runtime secrets. |

## Consent and provisioning notes

Microsoft Graph application roles are granted on each UAMI service principal by an Entra administrator. Treat this as an explicit consent step; do not assume Bicep deployment alone grants tenant-wide Graph application permissions.

## Replay protection

ServiceNow calls use `requestId` as the idempotency key, the `x-api-key` header as a shared secret stored in Key Vault, and a ServiceNow IP allowlist at the edge. Callback delivery also includes an idempotent `eventId` so ServiceNow can safely ignore duplicate callback attempts.
