# Azure Functions PowerShell profile (mock single-function app).
#
# This mock authenticates to Microsoft Graph with an app registration + client
# secret (OAuth2 client credentials), acquired via a plain REST call in
# Modules/Graph.psm1. No Az modules are imported, keeping cold start minimal.
