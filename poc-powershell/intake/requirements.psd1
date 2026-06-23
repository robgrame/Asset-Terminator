@{
    # No external PowerShell modules are required.
    # Microsoft Graph is accessed through the REST API using a Managed Identity
    # access token (Modules/Common.psm1 -> Get-GraphToken), which keeps the
    # function lightweight and avoids importing the large Microsoft.Graph SDK.
}
