using JobRunner.Infrastructure.Data;
using Microsoft.EntityFrameworkCore;

namespace JobRunner.Infrastructure.Data;

public class JobRunnerDbContext : DbContext
{
    public JobRunnerDbContext(DbContextOptions<JobRunnerDbContext> options)
        : base(options) { }

    public DbSet<Job> Jobs => Set<Job>();

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.ApplyConfigurationsFromAssembly(typeof(JobRunnerDbContext).Assembly);
    }
}
