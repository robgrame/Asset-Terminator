# Requirements for the Asset-Terminator API Function App (PowerShell).
# The application talks to Azure (SQL, Blob, Service Bus, Key Vault, Graph) using
# Managed Identity tokens acquired via REST inside the AT.* modules, so no heavy
# Az.* modules are required at runtime. Add Az.Accounts only if you switch to
# Connect-AzAccount -Identity.
@{
    # 'Az' = '12.*'
}
