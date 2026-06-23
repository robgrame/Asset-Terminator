using AssetTerminator.Core.Abstractions;
using AssetTerminator.Core.Domain;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Logging;

namespace AssetTerminator.Infrastructure.Data;

/// <summary>
/// EF Core implementation of the transactional state store.
/// </summary>
public sealed class SqlStateStore : IStateStore
{
    private readonly AssetTerminatorDbContext _db;
    private readonly ILogger<SqlStateStore> _logger;

    public SqlStateStore(AssetTerminatorDbContext db, ILogger<SqlStateStore> logger)
    {
        _db = db;
        _logger = logger;
    }

    public async Task<(DecommissionRecord Record, bool Created)> GetOrCreateAsync(
        DecommissionRecord record, CancellationToken ct)
    {
        var existing = await _db.Requests
            .Include(r => r.Actions)
            .FirstOrDefaultAsync(r => r.RequestId == record.RequestId, ct);
        if (existing is not null)
        {
            // Idempotency: the same requestId never triggers a second execution.
            _logger.LogInformation("Duplicate decommission request {RequestId}; returning existing record.", record.RequestId);
            return (existing, false);
        }

        _db.Requests.Add(record);
        try
        {
            await _db.SaveChangesAsync(ct);
            return (record, true);
        }
        catch (DbUpdateException)
        {
            // Possibly lost a race with a concurrent intake of the same requestId.
            _db.ChangeTracker.Clear();
            var winner = await _db.Requests.Include(r => r.Actions)
                .FirstOrDefaultAsync(r => r.RequestId == record.RequestId, ct);
            if (winner is not null)
                return (winner, false);
            throw;
        }
    }

    public Task<DecommissionRecord?> GetAsync(string requestId, CancellationToken ct) =>
        _db.Requests.Include(r => r.Actions)
            .FirstOrDefaultAsync(r => r.RequestId == requestId, ct);

    public async Task UpdateAsync(DecommissionRecord record, CancellationToken ct)
    {
        record.LastUpdatedAtUtc = DateTimeOffset.UtcNow;
        _db.Requests.Update(record);
        await _db.SaveChangesAsync(ct);
    }

    public async Task<IReadOnlyList<DecommissionRecord>> GetActiveAsync(int max, CancellationToken ct)
    {
        var terminal = new[] { RequestState.Completed, RequestState.Failed, RequestState.TimedOut, RequestState.GuardrailsFailed };
        return await _db.Requests
            .Include(r => r.Actions)
            .Where(r => !terminal.Contains(r.State))
            .OrderBy(r => r.LastUpdatedAtUtc)
            .Take(max)
            .ToListAsync(ct);
    }

    public async Task AddOverrideAsync(OverrideGrant grant, CancellationToken ct)
    {
        _db.Overrides.Add(grant);
        await _db.SaveChangesAsync(ct);
    }

    public async Task<IReadOnlyList<OverrideGrant>> GetOverridesAsync(string requestId, CancellationToken ct) =>
        await _db.Overrides.Where(o => o.RequestId == requestId).ToListAsync(ct);
}
