using AssetTerminator.Contracts;

namespace AssetTerminator.Core.Options;

/// <summary>Root configuration section name.</summary>
public static class ConfigSections
{
    public const string Root = "AssetTerminator";
}

/// <summary>Inbound authentication for ServiceNow calls (API key + IP allowlist).</summary>
public sealed class IngestionOptions
{
    public const string Section = "AssetTerminator:Ingestion";

    /// <summary>Header carrying the API key (default x-api-key).</summary>
    public string ApiKeyHeader { get; set; } = "x-api-key";

    /// <summary>
    /// Accepted API keys (Key Vault references). More than one allows rotation.
    /// </summary>
    public List<string> ApiKeys { get; set; } = new();

    /// <summary>Allowed source IPs/CIDRs. Empty = allow all (not recommended for prod).</summary>
    public List<string> IpAllowlist { get; set; } = new();
}

/// <summary>Configuration for a single guardrail (config-driven, no recompile).</summary>
public sealed class GuardrailOptions
{
    public bool Enabled { get; set; } = true;

    /// <summary>When true a failure blocks the wipe; when false it is recorded as a warning.</summary>
    public bool Mandatory { get; set; } = true;

    /// <summary>When true an approved override can bypass this guardrail's block.</summary>
    public bool Overridable { get; set; } = true;

    /// <summary>Optional numeric threshold (semantics are guardrail-specific, e.g. inactivity days).</summary>
    public int? Threshold { get; set; }

    /// <summary>Arbitrary extra settings for custom guardrails.</summary>
    public Dictionary<string, string> Settings { get; set; } = new(StringComparer.OrdinalIgnoreCase);
}

/// <summary>Map of guardrail id -> options.</summary>
public sealed class GuardrailsOptions
{
    public const string Section = "AssetTerminator:Guardrails";
    public Dictionary<string, GuardrailOptions> Items { get; set; } = new(StringComparer.OrdinalIgnoreCase);
}

/// <summary>Per-category SLA configuration.</summary>
public sealed class SlaCategoryOptions
{
    public TimeSpan MaxCompletionTime { get; set; } = TimeSpan.FromDays(7);

    /// <summary>Fraction of MaxCompletionTime after which the request is flagged "At Risk".</summary>
    public double AtRiskThreshold { get; set; } = 0.8;

    /// <summary>Polling interval for live status checks.</summary>
    public TimeSpan PollingInterval { get; set; } = TimeSpan.FromMinutes(30);

    /// <summary>Max retry attempts per sub-action before marking it Failed.</summary>
    public int MaxRetries { get; set; } = 10;
}

/// <summary>SLA configuration keyed by asset category.</summary>
public sealed class SlaOptions
{
    public const string Section = "AssetTerminator:Sla";
    public Dictionary<AssetCategory, SlaCategoryOptions> Categories { get; set; } = new();

    public SlaCategoryOptions For(AssetCategory category) =>
        Categories.TryGetValue(category, out var o) ? o : new SlaCategoryOptions();
}

/// <summary>Outbound ServiceNow callback configuration.</summary>
public sealed class CallbackOptions
{
    public const string Section = "AssetTerminator:Callback";
    public bool Enabled { get; set; } = true;
    public string? Url { get; set; }

    /// <summary>oauth2 | apikey. Credentials resolved from Key Vault.</summary>
    public string AuthMode { get; set; } = "oauth2";
    public string? TokenEndpoint { get; set; }
    public string? ClientId { get; set; }
    public string? ClientSecretRef { get; set; }
    public string? Scope { get; set; }
    public string? ApiKeyHeader { get; set; }
    public string? ApiKeyRef { get; set; }

    public int MaxRetries { get; set; } = 5;
    public TimeSpan BaseDelay { get; set; } = TimeSpan.FromSeconds(2);
}

/// <summary>Immutable audit (Blob WORM) configuration.</summary>
public sealed class AuditOptions
{
    public const string Section = "AssetTerminator:Audit";
    public string? BlobServiceUri { get; set; }
    public string ContainerName { get; set; } = "audit";

    /// <summary>WORM time-based retention in days, applied at the container/policy level.</summary>
    public int RetentionDays { get; set; } = 2555; // ~7 years
}

/// <summary>Orchestration / polling / give-up configuration.</summary>
public sealed class OrchestrationOptions
{
    public const string Section = "AssetTerminator:Orchestration";

    /// <summary>Continue-on-error: a failed sub-action does not abort the whole flow.</summary>
    public bool ContinueOnError { get; set; } = true;

    /// <summary>How often the polling engine re-checks active requests.</summary>
    public TimeSpan PollingInterval { get; set; } = TimeSpan.FromMinutes(15);

    /// <summary>Base delay for exponential backoff retries.</summary>
    public TimeSpan RetryBaseDelay { get; set; } = TimeSpan.FromMinutes(1);

    /// <summary>Cap for exponential backoff.</summary>
    public TimeSpan RetryMaxDelay { get; set; } = TimeSpan.FromHours(6);

    /// <summary>
    /// How often the orchestrator re-checks pre-wipe preventive actions (Autopilot/license/BIOS)
    /// while waiting for them to complete before issuing the wipe.
    /// </summary>
    public TimeSpan PreWipePollInterval { get; set; } = TimeSpan.FromMinutes(5);
}

/// <summary>
/// Pre-wipe preventive actions automatically injected for a Windows <c>Terminate</c> request.
/// These run (and, for the on-device ones, must complete) before the Intune wipe is issued.
/// </summary>
public sealed class PreWipeOptions
{
    public const string Section = "AssetTerminator:PreWipe";

    /// <summary>Delete the device's Windows Autopilot registration before the wipe.</summary>
    public bool DeleteFromAutopilot { get; set; } = true;

    /// <summary>Remove the Enterprise license (step down to Windows Pro) before the wipe.</summary>
    public bool RemoveEnterpriseLicense { get; set; } = true;

    /// <summary>Clear the BIOS/UEFI supervisor password via the OEM tool before the wipe.</summary>
    public bool RemoveBiosPassword { get; set; } = true;

    /// <summary>
    /// When true, a failed/incomplete on-device preventive action (license/BIOS) blocks the wipe.
    /// When false, the wipe proceeds even if a preventive action did not succeed.
    /// </summary>
    public bool RequireCompletionBeforeWipe { get; set; } = true;
}

/// <summary>Service Bus queue names.</summary>
public sealed class MessagingOptions
{
    public const string Section = "AssetTerminator:Messaging";
    public string? FullyQualifiedNamespace { get; set; }
    public string OrchestrationQueue { get; set; } = "decommission-orchestration";
    public string CloudActionsQueue { get; set; } = "decommission-cloud";
    public string OnPremActionsQueue { get; set; } = "decommission-onprem";
    public string CallbackDeadLetterQueue { get; set; } = "callback-deadletter";
}

/// <summary>Guardrail override / approval policy.</summary>
public sealed class OverrideOptions
{
    public const string Section = "AssetTerminator:Override";

    /// <summary>Number of distinct Approver sign-offs required before an override takes effect, per category.</summary>
    public Dictionary<AssetCategory, int> RequiredApprovals { get; set; } = new()
    {
        [AssetCategory.Standard] = 1,
        [AssetCategory.Vip] = 2,
        [AssetCategory.Critical] = 2
    };

    public int RequiredFor(AssetCategory category) =>
        RequiredApprovals.TryGetValue(category, out var n) ? Math.Max(1, n) : 1;
}

/// <summary>
/// Operational telemetry to Log Analytics custom tables via the Logs Ingestion API.
/// When <see cref="DcrEndpoint"/>/<see cref="DcrImmutableId"/> are not configured the
/// emitter is a no-op (telemetry still flows to Application Insights via ILogger).
/// </summary>
public sealed class ObservabilityOptions
{
    public const string Section = "AssetTerminator:Observability";

    /// <summary>Data Collection Endpoint logs-ingestion URI (https://...ingest.monitor.azure.com).</summary>
    public string? DcrEndpoint { get; set; }

    /// <summary>Data Collection Rule immutable id (dcr-...).</summary>
    public string? DcrImmutableId { get; set; }

    /// <summary>Stream name for request snapshots (e.g. Custom-DecommissionRequests_CL).</summary>
    public string RequestsStream { get; set; } = "Custom-DecommissionRequests_CL";
    public string ActionsStream { get; set; } = "Custom-DecommissionActions_CL";
    public string GuardrailsStream { get; set; } = "Custom-GuardrailResults_CL";
    public string CallbacksStream { get; set; } = "Custom-CallbackEvents_CL";
}
