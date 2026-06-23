# Azure Functions PowerShell profile.
#
# This POC talks to Microsoft Graph using a Managed Identity token obtained via
# REST (see Modules/Common.psm1 -> Get-GraphToken). We therefore do NOT import the
# Az modules here, keeping cold start fast and the footprint minimal.
#
# If you prefer to use Connect-AzAccount -Identity instead, add Az.Accounts to
# requirements.psd1 and uncomment the block below.

# if ($env:MSI_SECRET -and (Get-Module -ListAvailable Az.Accounts)) {
#     Connect-AzAccount -Identity
# }
