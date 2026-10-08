using JobRunner.Infrastructure.Data;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace JobRunner.Worker;

public class JobWorker : BackgroundService
{
    private static readonly TimeSpan PollInterval = TimeSpan.FromSeconds(1);
    private static readonly TimeSpan ReclaimInterval = TimeSpan.FromSeconds(15);

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
        _logger.LogInformation("Worker {WorkerId} starting", _workerId);

        var claimLoop = RunClaimLoopAsync(stoppingToken);
        var reclaimLoop = RunReclaimLoopAsync(stoppingToken);

        await Task.WhenAll(claimLoop, reclaimLoop);

        _logger.LogInformation("Worker {WorkerId} stopped", _workerId);
    }

    private async Task RunClaimLoopAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            List<ClaimedJob> claimed;

            // Scope #1: claim a batch. Short-lived.
            using (var scope = _scopeFactory.CreateScope())
            {
                var store = scope.ServiceProvider.GetRequiredService<JobStore>();
                claimed = await store.ClaimAsync(_workerId, batchSize: 10, ct);
            }

            if (claimed.Count == 0)
            {
                // Only sleep when idle. If we got jobs, loop straight back.
                var jitter = Random.Shared.Next(0, 250);
                try
                {
                    await Task.Delay(PollInterval + TimeSpan.FromMilliseconds(jitter), ct);
                }
                catch (OperationCanceledException)
                {
                    break;
                }
                continue;
            }

            foreach (var job in claimed)
            {
                if (ct.IsCancellationRequested)
                    break;
                await ProcessJobAsync(job, ct);
            }
        }
    }

    private async Task RunReclaimLoopAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try
            {
                await Task.Delay(ReclaimInterval, ct);
            }
            catch (OperationCanceledException)
            {
                break;
            }

            List<ClaimedJob> reclaimed;

            // Scope for reclaim: claim-and-return, then hand off.
            using (var scope = _scopeFactory.CreateScope())
            {
                var store = scope.ServiceProvider.GetRequiredService<JobStore>();
                reclaimed = await store.ReclaimStaleAsync(_workerId, ct);
            }

            if (reclaimed.Count == 0)
                continue;

            _logger.LogInformation("Reclaimed {Count} stale jobs", reclaimed.Count);

            // Hand them to the same execution path. Scope per job.
            foreach (var job in reclaimed)
            {
                if (ct.IsCancellationRequested)
                    break;
                await ProcessJobAsync(job, ct);
            }
        }
    }

    private async Task ProcessJobAsync(ClaimedJob job, CancellationToken ct)
    {
        // Fresh scope per job: isolation. One bad job can't poison its neighbours.
        using var scope = _scopeFactory.CreateScope();
        var store = scope.ServiceProvider.GetRequiredService<JobStore>();

        _logger.LogInformation(
            "Processing job {JobId} (fence {FenceToken}, attempt {Attempt})",
            job.Id,
            job.FenceToken,
            job.AttemptCount
        );

        try
        {
            // TODO: dispatch on job.JobType to a handler.
            // For now, just simulate work and mark success.
            await Task.Delay(50, ct);

            await store.MarkSucceededAsync(job.Id, job.FenceToken, ct);

            _logger.LogInformation("Job {JobId} succeeded", job.Id);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            // Shutdown requested mid-job. Don't mark success or failure —
            // let the stale reclaim pick it up on the next process.
            _logger.LogWarning("Job {JobId} interrupted by shutdown", job.Id);
            throw;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Job {JobId} failed", job.Id);
            await store.MarkFailedAsync(job.Id, job.FenceToken, ex.Message, ct);
        }
    }
}
