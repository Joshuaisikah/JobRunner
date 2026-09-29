using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace JobRunner.Infrastructure.Data;

public class JobConfiguration : IEntityTypeConfiguration<Job>
{
    public void Configure(EntityTypeBuilder<Job> builder)
    {
        builder.ToTable("jobs");
        builder.HasKey(j => j.Id);
        builder.Property(j => j.Id).UseIdentityAlwaysColumn();
        builder.Property(j => j.JobType).IsRequired().HasMaxLength(200);
        builder.Property(j => j.Payload).IsRequired().HasColumnType("jsonb");
        builder.Property(j => j.Status).HasConversion<string>().HasMaxLength(20);
        builder.Property(j => j.LockedBy).HasMaxLength(100);
        builder
            .HasIndex(j => new { j.RunAt, j.Id })
            .HasFilter("\"Status\" = 'Pending'")
            .HasDatabaseName("IX_jobs_claim");
    }
}
