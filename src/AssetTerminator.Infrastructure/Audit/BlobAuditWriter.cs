using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Azure;
using Azure.Storage.Blobs;
using Azure.Storage.Blobs.Models;
using AssetTerminator.Core.Abstractions;
using Microsoft.Extensions.Logging;

namespace AssetTerminator.Infrastructure.Audit;

/// <summary>
/// Append-only audit writer backed by Azure Blob Storage with a WORM immutability
/// policy. Each <see cref="AuditRecord"/> is written as its own immutable block blob
/// under the prefix "{requestId}/" with a zero-padded sequence, and is hash-chained
/// to the previous record (SHA-256 over canonical content + previous hash) for
/// tamper-evidence.
/// </summary>
public sealed class BlobAuditWriter : IAuditWriter
{
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = false
    };

    private readonly BlobContainerClient _container;
    private readonly ILogger<BlobAuditWriter> _logger;

    public BlobAuditWriter(BlobContainerClient container, ILogger<BlobAuditWriter> logger)
    {
        _container = container;
        _logger = logger;
    }

    public async Task AppendAsync(AuditRecord record, CancellationToken ct)
    {
        // Determine the next sequence number and previous hash by inspecting the chain.
        var prefix = $"{Sanitize(record.RequestId)}/";
        var existing = new List<string>();
        await foreach (var item in _container.GetBlobsAsync(prefix: prefix, traits: BlobTraits.None, states: BlobStates.None, cancellationToken: ct))
            existing.Add(item.Name);

        existing.Sort(StringComparer.Ordinal);
        var seq = existing.Count;

        string? previousHash = null;
        if (existing.Count > 0)
        {
            var last = await DownloadAsync(existing[^1], ct);
            previousHash = last?.Hash;
        }

        record.PreviousHash = previousHash;
        record.Hash = ComputeHash(record, previousHash);

        var blobName = $"{prefix}{seq:D8}-{record.TimestampUtc.UtcDateTime:yyyyMMddHHmmssfff}.json";
        var blob = _container.GetBlobClient(blobName);
        var payload = JsonSerializer.SerializeToUtf8Bytes(record, Json);

        // Write-once: never overwrite. WORM policy enforces immutability at the service level.
        await blob.UploadAsync(
            new BinaryData(payload).ToStream(),
            new BlobUploadOptions
            {
                Conditions = new BlobRequestConditions { IfNoneMatch = ETag.All },
                HttpHeaders = new BlobHttpHeaders { ContentType = "application/json" }
            },
            ct);

        _logger.LogInformation("Audit appended {Blob} action={Action} outcome={Outcome}", blobName, record.Action, record.Outcome);
    }

    public async Task<IReadOnlyList<AuditRecord>> ReadTimelineAsync(string requestId, CancellationToken ct)
    {
        var prefix = $"{Sanitize(requestId)}/";
        var names = new List<string>();
        await foreach (var item in _container.GetBlobsAsync(prefix: prefix, traits: BlobTraits.None, states: BlobStates.None, cancellationToken: ct))
            names.Add(item.Name);
        names.Sort(StringComparer.Ordinal);

        var result = new List<AuditRecord>(names.Count);
        foreach (var name in names)
        {
            var rec = await DownloadAsync(name, ct);
            if (rec is not null)
                result.Add(rec);
        }
        return result;
    }

    private async Task<AuditRecord?> DownloadAsync(string blobName, CancellationToken ct)
    {
        try
        {
            var resp = await _container.GetBlobClient(blobName).DownloadContentAsync(ct);
            return resp.Value.Content.ToObjectFromJson<AuditRecord>(Json);
        }
        catch (RequestFailedException ex) when (ex.Status == 404)
        {
            return null;
        }
    }

    private static string ComputeHash(AuditRecord record, string? previousHash)
    {
        // Hash the canonical content excluding the Hash field itself.
        var canonical = new
        {
            record.CorrelationId,
            record.RequestId,
            record.TicketNumber,
            record.AssetId,
            record.Action,
            record.TargetEnvironment,
            record.Actor,
            Timestamp = record.TimestampUtc.UtcDateTime.ToString("O"),
            record.Outcome,
            record.Reason,
            record.GuardrailResults,
            PreviousHash = previousHash
        };
        var bytes = JsonSerializer.SerializeToUtf8Bytes(canonical, Json);
        var hash = SHA256.HashData(bytes);
        return Convert.ToHexString(hash);
    }

    private static string Sanitize(string requestId)
    {
        var sb = new StringBuilder(requestId.Length);
        foreach (var c in requestId)
            sb.Append(char.IsLetterOrDigit(c) || c is '-' or '_' ? c : '_');
        return sb.ToString();
    }
}
