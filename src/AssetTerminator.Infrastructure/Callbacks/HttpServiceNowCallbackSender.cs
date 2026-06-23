using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using Azure.Messaging.ServiceBus;
using AssetTerminator.Contracts;
using AssetTerminator.Core.Abstractions;
using AssetTerminator.Core.Options;
using AssetTerminator.Infrastructure.Secrets;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using Polly;
using Polly.Retry;

namespace AssetTerminator.Infrastructure.Callbacks;

/// <summary>
/// Pushes callbacks to ServiceNow over HTTP with exponential-backoff retry. When the
/// retry budget is exhausted the callback is dead-lettered to a Service Bus queue for
/// later inspection/replay. Each callback carries a unique eventId so ServiceNow can
/// dedupe.
/// </summary>
public sealed class HttpServiceNowCallbackSender : ICallbackSender
{
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    private readonly HttpClient _http;
    private readonly ISecretResolver _secrets;
    private readonly ServiceBusClient _serviceBus;
    private readonly IOptionsMonitor<CallbackOptions> _options;
    private readonly MessagingOptions _messaging;
    private readonly ILogger<HttpServiceNowCallbackSender> _logger;

    public HttpServiceNowCallbackSender(
        HttpClient http,
        ISecretResolver secrets,
        ServiceBusClient serviceBus,
        IOptionsMonitor<CallbackOptions> options,
        IOptions<MessagingOptions> messaging,
        ILogger<HttpServiceNowCallbackSender> logger)
    {
        _http = http;
        _secrets = secrets;
        _serviceBus = serviceBus;
        _options = options;
        _messaging = messaging.Value;
        _logger = logger;
    }

    public async Task SendAsync(ServiceNowCallback callback, CancellationToken ct)
    {
        var cfg = _options.CurrentValue;
        if (!cfg.Enabled || string.IsNullOrWhiteSpace(cfg.Url))
        {
            _logger.LogDebug("Callback disabled or no URL configured; skipping {EventId}", callback.EventId);
            return;
        }

        var pipeline = BuildPipeline(cfg);

        try
        {
            await pipeline.ExecuteAsync(async token =>
            {
                using var request = new HttpRequestMessage(HttpMethod.Post, cfg.Url)
                {
                    Content = JsonContent.Create(callback, options: Json)
                };
                request.Headers.Add("x-event-id", callback.EventId); // idempotency hint
                await ApplyAuthAsync(request, cfg, token);

                using var response = await _http.SendAsync(request, token);
                if (!response.IsSuccessStatusCode)
                    throw new HttpRequestException($"ServiceNow callback returned {(int)response.StatusCode}");
            }, ct);

            _logger.LogInformation("Callback {EventId} for {RequestId} delivered ({Status})",
                callback.EventId, callback.RequestId, callback.OverallStatus);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Callback {EventId} for {RequestId} failed after retries; dead-lettering",
                callback.EventId, callback.RequestId);
            await DeadLetterAsync(callback, ct);
        }
    }

    private ResiliencePipeline BuildPipeline(CallbackOptions cfg) =>
        new ResiliencePipelineBuilder()
            .AddRetry(new RetryStrategyOptions
            {
                ShouldHandle = new PredicateBuilder().Handle<HttpRequestException>().Handle<TaskCanceledException>(),
                MaxRetryAttempts = cfg.MaxRetries,
                BackoffType = DelayBackoffType.Exponential,
                Delay = cfg.BaseDelay,
                UseJitter = true
            })
            .Build();

    private async Task ApplyAuthAsync(HttpRequestMessage request, CallbackOptions cfg, CancellationToken ct)
    {
        switch (cfg.AuthMode?.ToLowerInvariant())
        {
            case "apikey":
                var key = await _secrets.ResolveAsync(cfg.ApiKeyRef, ct);
                if (!string.IsNullOrEmpty(key) && !string.IsNullOrEmpty(cfg.ApiKeyHeader))
                    request.Headers.TryAddWithoutValidation(cfg.ApiKeyHeader, key);
                break;
            case "oauth2":
            default:
                var token = await AcquireOAuthTokenAsync(cfg, ct);
                if (!string.IsNullOrEmpty(token))
                    request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
                break;
        }
    }

    private async Task<string?> AcquireOAuthTokenAsync(CallbackOptions cfg, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(cfg.TokenEndpoint) || string.IsNullOrWhiteSpace(cfg.ClientId))
            return null;
        var secret = await _secrets.ResolveAsync(cfg.ClientSecretRef, ct);
        var form = new Dictionary<string, string>
        {
            ["grant_type"] = "client_credentials",
            ["client_id"] = cfg.ClientId!,
            ["client_secret"] = secret ?? string.Empty
        };
        if (!string.IsNullOrWhiteSpace(cfg.Scope))
            form["scope"] = cfg.Scope!;

        using var resp = await _http.PostAsync(cfg.TokenEndpoint, new FormUrlEncodedContent(form), ct);
        resp.EnsureSuccessStatusCode();
        using var stream = await resp.Content.ReadAsStreamAsync(ct);
        using var doc = await JsonDocument.ParseAsync(stream, cancellationToken: ct);
        return doc.RootElement.TryGetProperty("access_token", out var tok) ? tok.GetString() : null;
    }

    private async Task DeadLetterAsync(ServiceNowCallback callback, CancellationToken ct)
    {
        try
        {
            await using var sender = _serviceBus.CreateSender(_messaging.CallbackDeadLetterQueue);
            var body = JsonSerializer.SerializeToUtf8Bytes(callback, Json);
            await sender.SendMessageAsync(new ServiceBusMessage(body)
            {
                ContentType = "application/json",
                MessageId = callback.EventId
            }, ct);
        }
        catch (Exception ex)
        {
            // Last resort: the audit trail still records the callback attempt.
            _logger.LogCritical(ex, "Failed to dead-letter callback {EventId}", callback.EventId);
        }
    }
}
