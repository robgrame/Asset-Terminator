@{
    # PSScriptAnalyzer settings for the parallel PowerShell source tree.
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # Functions modules and REST wrappers legitimately use Write-Host/Information
        # style structured logging; keep the noise focused on real issues.
        'PSAvoidUsingWriteHost',
        # New-* builders and Get-*s enum-set accessors are pure/in-memory; the
        # ShouldProcess and singular-noun rules are false positives for these
        # deliberate naming conventions.
        'PSUseShouldProcessForStateChangingFunctions',
        'PSUseSingularNouns',
        # Guardrail functions share a uniform (Device, Settings) signature by
        # contract even when one parameter is unused by a given rule.
        'PSReviewUnusedParameter',
        # Best-effort status extraction intentionally swallows conversion errors.
        'PSAvoidUsingEmptyCatchBlock',
        # Manifests use non-ASCII (em dash) in descriptions; BOM is not required.
        'PSUseBOMForUnicodeEncodedFile',
        # Functions apps ship a requirements.psd1 (managed-dependency file), which is
        # not a module manifest; the manifest-field rule is a false positive for it.
        'PSMissingModuleManifestField'
    )
}
