# No external PowerShell modules are required: the mock talks to Microsoft Graph
# directly over REST (see Modules/Graph.psm1). Managed dependencies are disabled
# in host.json to keep cold start fast.
@{
}
