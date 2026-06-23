using System.Text.Json;
using AssetTerminator.Core.Abstractions;
using AssetTerminator.Core.Domain;
using Microsoft.EntityFrameworkCore;

namespace AssetTerminator.Infrastructure.Data;

/// <summary>
/// EF Core context for the transactional current-state store (Azure SQL serverless).
/// Holds mutable, queryable state only — never the immutable audit.
/// </summary>
public sealed class AssetTerminatorDbContext : DbContext
{
    public AssetTerminatorDbContext(DbContextOptions<AssetTerminatorDbContext> options)
        : base(options)
    {
    }

    public DbSet<DecommissionRecord> Requests => Set<DecommissionRecord>();
    public DbSet<SubAction> Actions => Set<SubAction>();
    public DbSet<OverrideGrant> Overrides => Set<OverrideGrant>();

    protected override void OnModelCreating(ModelBuilder b)
    {
        var stringListConverter = new Microsoft.EntityFrameworkCore.Storage.ValueConversion.ValueConverter<List<string>, string>(
            v => JsonSerializer.Serialize(v, (JsonSerializerOptions?)null),
            v => string.IsNullOrWhiteSpace(v)
                ? new List<string>()
                : JsonSerializer.Deserialize<List<string>>(v, (JsonSerializerOptions?)null) ?? new List<string>());

        b.Entity<DecommissionRecord>(e =>
        {
            e.ToTable("DecommissionRequests");
            e.HasKey(x => x.RequestId);
            e.Property(x => x.RequestId).HasMaxLength(200);
            e.Property(x => x.CorrelationId).HasMaxLength(64).IsRequired();
            e.HasIndex(x => x.CorrelationId);
            e.Property(x => x.AssetId).HasMaxLength(200);
            e.Property(x => x.DeviceName).HasMaxLength(256);
            e.Property(x => x.SerialNumber).HasMaxLength(128);
            e.Property(x => x.PrimaryUserUpn).HasMaxLength(256);
            e.Property(x => x.TicketNumber).HasMaxLength(128);
            e.Property(x => x.Requestor).HasMaxLength(256);
            e.Property(x => x.State).HasConversion<string>().HasMaxLength(32);
            e.Property(x => x.SlaState).HasConversion<string>().HasMaxLength(32);
            e.Property(x => x.DeviceType).HasConversion<string>().HasMaxLength(32);
            e.Property(x => x.AssetCategory).HasConversion<string>().HasMaxLength(32);
            e.Property(x => x.RequestJson);
            e.HasIndex(x => x.State);
            e.HasMany(x => x.Actions)
                .WithOne()
                .HasForeignKey(a => a.RequestId)
                .OnDelete(DeleteBehavior.Cascade);
        });

        b.Entity<SubAction>(e =>
        {
            e.ToTable("DecommissionActions");
            e.HasKey(x => x.Id);
            e.Property(x => x.Id).ValueGeneratedOnAdd();
            e.Property(x => x.RequestId).HasMaxLength(200).IsRequired();
            e.Property(x => x.Target).HasConversion<string>().HasMaxLength(32);
            e.Property(x => x.Action).HasMaxLength(64);
            e.Property(x => x.Status).HasConversion<string>().HasMaxLength(32);
            e.Property(x => x.FinalOutcome).HasMaxLength(64);
            e.HasIndex(x => new { x.RequestId, x.Target });
        });

        b.Entity<OverrideGrant>(e =>
        {
            e.ToTable("GuardrailOverrides");
            e.HasKey(x => x.Id);
            e.Property(x => x.Id).ValueGeneratedOnAdd();
            e.Property(x => x.RequestId).HasMaxLength(200).IsRequired();
            e.Property(x => x.ApproverUpn).HasMaxLength(256).IsRequired();
            e.Property(x => x.Reason).HasMaxLength(2000).IsRequired();
            e.Property(x => x.GuardrailIds).HasConversion(stringListConverter);
            e.HasIndex(x => x.RequestId);
        });
    }
}
