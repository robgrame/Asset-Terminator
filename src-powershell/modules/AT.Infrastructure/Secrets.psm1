# Secrets.psm1  (nested in AT.Infrastructure)
# Key Vault secret resolver over REST with a Managed Identity token (passwordless).
# Parity with AssetTerminator.Infrastructure.Secrets.ISecretResolver.
#
# Configuration (app settings):
#   KEYVAULT_URI : https://<vault>.vault.azure.net
#
# A "secret name" may be a bare name or a full secret URI. Empty/null returns $null.

Set-StrictMode -Version Latest

$script:VaultResource = 'https://vault.azure.net'
$script:VaultApiVersion = '7.4'

function Resolve-Secret {
    <#
        .SYNOPSIS
            Resolves a Key Vault secret value by name or full URI. Returns $null when
            the reference is empty.
    #>
    [CmdletBinding()]
    param([string] $Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }

    $uri = if ($Name -match '^https?://') {
        "$($Name.TrimEnd('/'))?api-version=$script:VaultApiVersion"
    }
    else {
        $vault = $env:KEYVAULT_URI
        if (-not $vault) { throw 'KEYVAULT_URI app setting is not configured.' }
        "$($vault.TrimEnd('/'))/secrets/$Name?api-version=$script:VaultApiVersion"
    }

    $resp = Invoke-AtRetry -ScriptBlock {
        $token = Get-IdentityToken -Resource $script:VaultResource
        Invoke-RestMethod -Method Get -Uri $uri -Headers @{ Authorization = "Bearer $token" } -ErrorAction Stop
    }
    return $resp.value
}

Export-ModuleMember -Function Resolve-Secret
