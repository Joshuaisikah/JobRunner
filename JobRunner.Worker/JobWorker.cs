using System.Collections.Concurrent;
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

    // BeatDeadline < HeartbeatInterval <= StaleTimeout / 3
    private static readonly TimeSpan HeartbeatInterval = TimeSpan.FromSeconds(10); // keeps ClaimedAt fresh; tolerates 2 missed beats under 30 s stale
    private static readonly TimeSpan BeatDeadline = TimeSpan.FromSeconds(3); // short enough to leave margin before the job becomes stealable
    private static readonly TimeSpan JobTimeout = TimeSpan.FromSeconds(60); // independent of lease; only enforced while the handler actually runs

    // Jobs this worker currently holds. Value = (FenceToken, per-job CTS that the heartbeat can cancel).
    private readonly ConcurrentDictionary<
        long,
        (int Token, CancellationTokenSource Cts)
    > _heldJobs = new();

    private readonly IServiceScopeFactory _scopeFactory;
    private readonly ILogger<JobWorker> _logger;
    private readonly IHostApplicationLifetime _lifetime;
    private readonly string _workerId = Guid.NewGuid().ToString("N");

    public JobWorker(
        IServiceScopeFactory scopeFactory,
        ILogger<JobWorker> logger,
        IHostApplicationLifetime lifetime
    )
    {
        _scopeFactory = scopeFactory;
        _logger = logger;
        _lifetime = lifetime;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        _logger.LogInformation("JobWorker started with WorkerId: {WorkerId}", _workerId);
        _ = RunHeartbeatLoopAsync(stoppingToken);

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

                        // Register the whole batch BEFORE any processing starts
                        foreach (var job in reclaimedJobs)
                            _heldJobs[job.Id] = (job.FenceToken, new CancellationTokenSource());

                        try
                        {
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
                        finally
                        {
                            // Drop any jobs that never started or were abandoned mid-batch
                            // so the heartbeat stops renewing them and they can go stale.
                            foreach (var job in reclaimedJobs)
                            {
                                if (_heldJobs.TryRemove(job.Id, out var entry))
                                    entry.Cts.Dispose();
                            }
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

                    // Register the whole batch BEFORE any processing starts
                    foreach (var job in claimedJobs)
                        _heldJobs[job.Id] = (job.FenceToken, new CancellationTokenSource());

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
                break;
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Error occurred in worker main loop");
            }

            if (!workFound && !stoppingToken.IsCancellationRequested)
                await Task.Delay(PollInterval, stoppingToken);
        }

        _logger.LogInformation("JobWorker stopped gracefully.");
    }

    private async Task ProcessJobAsync(ClaimedJob job, CancellationToken stoppingToken)
    {
        using var jobScope = _scopeFactory.CreateScope();
        var jobStore = jobScope.ServiceProvider.GetRequiredService<JobStore>();
        var handlers = jobScope.ServiceProvider.GetRequiredService<IEnumerable<IJobHandler>>();
        var handler = handlers.FirstOrDefault(h => h.JobType == job.JobType);

        if (handler == null)
        {
            var errorMsg = $"No registered handler found for job type '{job.JobType}'";
            _logger.LogError("{Error}", errorMsg);
            if (_heldJobs.TryRemove(job.Id, out var missing))
                missing.Cts.Dispose();
            if (!stoppingToken.IsCancellationRequested)
                await jobStore.FailAsync(job, errorMsg, permanent: true, stoppingToken);
            return;
        }

        if (!_heldJobs.TryGetValue(job.Id, out var held))
        {
            // Should never happen – we always register before calling ProcessJobAsync
            _logger.LogError("Job {JobId} is not in _heldJobs – aborting", job.Id);
            return;
        }

        using var jobTimeoutCts = new CancellationTokenSource(JobTimeout);
        using var linkedCts = CancellationTokenSource.CreateLinkedTokenSource(
            stoppingToken,
            held.Cts.Token, // per-job lease token
            jobTimeoutCts.Token
        );

        try
        {
            _logger.LogInformation(
                "Executing job {JobId} using handler {HandlerType}",
                job.Id,
                handler.GetType().Name
            );

            await handler.ExecuteAsync(job, linkedCts.Token);

            // Only complete if we still own the fence and weren't cancelled
            if (!linkedCts.Token.IsCancellationRequested)
            {
                var success = await jobStore.CompleteAsync(job.Id, job.FenceToken, stoppingToken);
                if (success)
                    _logger.LogInformation("Successfully completed job {JobId}", job.Id);
                else
                    _logger.LogWarning(
                        "Lost fence token ownership for job {JobId} on complete",
                        job.Id
                    );
            }
        }
        // 1. Worker is shutting down
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
        {
            _logger.LogWarning("Job {JobId} interrupted by worker shutdown", job.Id);
            // Leave it Running – stale reclaim will pick it up later
        }
        // 2. This specific job lost its lease (heartbeat saw it missing)
        catch (OperationCanceledException) when (held.Cts.IsCancellationRequested)
        {
            _logger.LogWarning("Job {JobId} cancelled – lease lost (heartbeat)", job.Id);
            // Do NOT call FailAsync; another worker already owns it (or will)
        }
        // 3. Soft job timeout
        catch (OperationCanceledException) when (jobTimeoutCts.IsCancellationRequested)
        {
            _logger.LogWarning("Job {JobId} timed out after {Timeout}", job.Id, JobTimeout);
            await jobStore.FailAsync(
                job,
                $"Job timed out after {JobTimeout}",
                permanent: false,
                stoppingToken
            );
        }
        // 4. Real failure
        catch (Exception ex)
        {
            _logger.LogError(ex, "Execution failed for job {JobId}", job.Id);
            await jobStore.FailAsync(job, ex.ToString(), permanent: false, stoppingToken);
        }
        finally
        {
            if (_heldJobs.TryRemove(job.Id, out var entry))
                entry.Cts.Dispose();
        }
    }

    private async Task RunHeartbeatLoopAsync(CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(HeartbeatInterval);
        var consecutiveMisses = 0;

        while (await timer.WaitForNextTickAsync(stoppingToken))
        {
            var snapshot = _heldJobs.ToArray();
            if (snapshot.Length == 0)
            {
                consecutiveMisses = 0;
                continue;
            }

            var ids = snapshot.Select(kv => kv.Key).ToArray();
            var tokens = snapshot.Select(kv => kv.Value.Token).ToArray();

            try
            {
                using var beatCts = CancellationTokenSource.CreateLinkedTokenSource(stoppingToken);
                beatCts.CancelAfter(BeatDeadline);

                List<long> refreshed;
                using (var scope = _scopeFactory.CreateScope())
                {
                    var store = scope.ServiceProvider.GetRequiredService<JobStore>();
                    refreshed = await store.HeartbeatAsync(ids, tokens, beatCts.Token);
                }

                var refreshedSet = refreshed.ToHashSet();
                foreach (var (id, _) in snapshot)
                {
                    if (!refreshedSet.Contains(id) && _heldJobs.TryRemove(id, out var entry))
                    {
                        entry.Cts.Cancel(); // cancels only this job’s handler
                        entry.Cts.Dispose();
                        _logger.LogWarning("Lost lease on job {JobId} (heartbeat missed it)", id);
                    }
                }

                consecutiveMisses = 0;
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;
            }
            catch (Exception ex)
            {
                consecutiveMisses++;
                _logger.LogWarning(
                    ex,
                    "Heartbeat failed (miss {Miss}/2). Held jobs: {Count}",
                    consecutiveMisses,
                    snapshot.Length
                );

                if (consecutiveMisses >= 2)
                {
                    _logger.LogError("Two consecutive heartbeats failed – stopping the worker");
                    _lifetime.StopApplication(); // process exits cleanly
                    return;
                }
            }
        }
    }
}
