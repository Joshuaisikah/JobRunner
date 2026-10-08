using JobRunner.Infrastructure.Data;
using JobRunner.Worker.Handlers;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace JobRunner.Worker;

public class JobWorker : BackgroundService
{
    private static readonly TimeSpan PollInterval = TimeSpan.FromSeconds(1);
    private static readonly TimeSpan ReclaimInterval = TimeSpan.FromSeconds(15);
    private static readonly TimeSpan StaleTimeout = TimeSpan.FromSeconds(30);

    private readonly IServiceScopeFactory _scopeFactory;
    private readonly ILogger<JobWorker> _logger;
    private readonly string _workerId = Guid.NewGuid().ToString("N");

    public JobWorker(IServiceScopeFactory scopeFactory, ILogger<JobWorker> logger)
    {
        _scopeFactory = scopeFactory;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        _logger.LogInformation("JobWorker started with WorkerId: {WorkerId}", _workerId);
        var lastReclaimTime = DateTime.UtcNow;

        while (!stoppingToken.IsCancellationRequested)
        {
            bool workFound = false;

            try
            {
                // 1. Reclaim stale jobs periodically
                if (DateTime.UtcNow - lastReclaimTime >= ReclaimInterval)
                {
                    using var reclaimScope = _scopeFactory.CreateScope();
                    var jobStore = reclaimScope.ServiceProvider.GetRequiredService<JobStore>();

                    var reclaimedJobs = await jobStore.ReclaimStaleAsync(
                        _workerId,
                        StaleTimeout,
                        batch: 10,
                        stoppingToken
                    );
                    if (reclaimedJobs.Count > 0)
                    {
                        workFound = true;
                        foreach (var job in reclaimedJobs)
                        {
                            _logger.LogWarning(
                                "Reclaimed stale job {JobId} of type {JobType} (Attempt {Attempt}/{Max})",
                                job.Id,
                                job.JobType,
                                job.Attempts,
                                job.MaxAttempts
                            );

                            await ProcessJobAsync(job, stoppingToken);
                        }
                    }
                    lastReclaimTime = DateTime.UtcNow;
                }

                // 2. Claim new pending jobs
                using var claimScope = _scopeFactory.CreateScope();
                var store = claimScope.ServiceProvider.GetRequiredService<JobStore>();

                var claimedJobs = await store.ClaimAsync(_workerId, batch: 10, stoppingToken);
                if (claimedJobs.Count > 0)
                {
                    workFound = true;
                    foreach (var job in claimedJobs)
                    {
                        _logger.LogInformation(
                            "Claimed job {JobId} of type {JobType}",
                            job.Id,
                            job.JobType
                        );
                        await ProcessJobAsync(job, stoppingToken);
                    }
                }
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                // Graceful shutdown requested; suppress main loop cancellation errors
                break;
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Error occurred in worker main loop");
            }

            // Only sleep if neither claim nor reclaim found any work
            if (!workFound && !stoppingToken.IsCancellationRequested)
            {
                await Task.Delay(PollInterval, stoppingToken);
            }
        }

        _logger.LogInformation("JobWorker stopped gracefully.");
    }

    private async Task ProcessJobAsync(ClaimedJob job, CancellationToken stoppingToken)
    {
        // Fresh scope per individual job execution
        using var jobScope = _scopeFactory.CreateScope();
        var jobStore = jobScope.ServiceProvider.GetRequiredService<JobStore>();
        var handlers = jobScope.ServiceProvider.GetRequiredService<IEnumerable<IJobHandler>>();

        var handler = handlers.FirstOrDefault(h => h.JobType == job.JobType);

        if (handler == null)
        {
            var errorMsg = $"No registered handler found for job type '{job.JobType}'";
            _logger.LogError("{Error}", errorMsg);

            if (!stoppingToken.IsCancellationRequested)
            {
                await jobStore.FailAsync(job, errorMsg, permanent: true, stoppingToken);
            }
            return;
        }

        try
        {
            _logger.LogInformation(
                "Executing job {JobId} using handler {HandlerType}",
                job.Id,
                handler.GetType().Name
            );

            await handler.ExecuteAsync(job, stoppingToken);

            if (!stoppingToken.IsCancellationRequested)
            {
                var success = await jobStore.CompleteAsync(job.Id, job.FenceToken, stoppingToken);
                if (success)
                {
                    _logger.LogInformation("Successfully completed job {JobId}", job.Id);
                }
                else
                {
                    _logger.LogWarning(
                        "Lost fence token ownership for job {JobId} upon completion attempt",
                        job.Id
                    );
                }
            }
        }
        catch (Exception ex) when (stoppingToken.IsCancellationRequested)
        {
            _logger.LogWarning("Job {JobId} execution interrupted due to worker shutdown.", job.Id);
            // Leave the job locked/running or let stale reclaim handle it cleanly upon restart
            // without crashing on a cancelled DB context token.
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Execution failed for job {JobId}", job.Id);
            await jobStore.FailAsync(job, ex.ToString(), permanent: false, stoppingToken);
        }
    }
}
