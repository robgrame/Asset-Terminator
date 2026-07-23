# AT.Infrastructure.psm1
# Aggregating root for the infrastructure adapters. The actual implementations
# live in the nested modules declared in the manifest (Sla.psm1, Audit.psm1, and
# further adapters added incrementally: SqlStateStore, Messaging, Callbacks,
# Secrets, Observability). Parity with AssetTerminator.Infrastructure.
Set-StrictMode -Version Latest
