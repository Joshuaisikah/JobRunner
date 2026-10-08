using System.Text.Json;
using JobRunner.Api.DTOs;
using JobRunner.Infrastructure;
using JobRunner.Infrastructure.Data;
using Microsoft.EntityFrameworkCore;

namespace JobRunner.Api.Services;

public class JobService
{
    private const int DefaultMaxAttempts = 5;

    private readonly JobRunnerDbContext _dbContext;

    public JobService(JobRunnerDbContext dbContext)
    {
        _dbContext = dbContext;
    }

    public async Task<Result<JobResponseDto>> CreateJobAsync(
        JobRequestDto jobRequest,
        CancellationToken ct
    )
    {
        if (!JobType.All.Contains(jobRequest.JobType))
            return Result<JobResponseDto>.Failure(JobError.UnknownJobType);

        // Reject missing / non-object payloads early (poison message → 400)
        if (jobRequest.Payload.ValueKind is not (JsonValueKind.Object or JsonValueKind.Array))
            return Result<JobResponseDto>.Failure(JobError.InvalidPayload);

        // Force UTC – reject non-UTC values
        DateTime runAt;
        if (jobRequest.RunAt is null)
        {
            runAt = DateTime.UtcNow;
        }
        else if (jobRequest.RunAt.Value.Kind != DateTimeKind.Utc)
        {
            return Result<JobResponseDto>.Failure(JobError.InvalidRunAt);
        }
        else
        {
            runAt = jobRequest.RunAt.Value;
        }

        var maxAttempts = jobRequest.MaxAttempts ?? DefaultMaxAttempts;

        var job = new Job
        {
            JobType = jobRequest.JobType,
            Payload = jobRequest.Payload.GetRawText(),
            Status = JobStatus.Pending,
            CreatedAt = DateTime.UtcNow,
            RunAt = runAt,
            MaxAttempts = maxAttempts, // ← persist per-job value
            Attempts = 0,
            FenceToken = 0,
        };

        await _dbContext.Jobs.AddAsync(job, ct);
        await _dbContext.SaveChangesAsync(ct);

        return Result<JobResponseDto>.Success(
            new JobResponseDto(job.Id, job.Status.ToString(), job.CreatedAt, job.RunAt)
        );
    }

    public async Task<PagedResultDto<JobResponseDto>> GetJobsAsync(
        JobStatus? status,
        int page,
        int pageSize,
        CancellationToken ct
    )
    {
        const int maxPageSize = 100;
        if (page < 1)
            page = 1;
        if (pageSize < 1)
            pageSize = 20;
        if (pageSize > maxPageSize)
            pageSize = maxPageSize;

        var query = _dbContext.Jobs.AsNoTracking();
        if (status is not null)
            query = query.Where(j => j.Status == status.Value);

        var totalCount = await query.CountAsync(ct);

        var jobs = await query
            .OrderByDescending(j => j.CreatedAt)
            .ThenByDescending(j => j.Id) // ← stable tie-breaker
            .Skip((page - 1) * pageSize)
            .Take(pageSize)
            .ToListAsync(ct);

        var items = jobs.Select(j => new JobResponseDto(
                j.Id,
                j.Status.ToString(),
                j.CreatedAt,
                j.RunAt
            ))
            .ToList();

        return new PagedResultDto<JobResponseDto>(items, totalCount, page, pageSize);
    }

    public async Task<Result<JobResponseDto>> GetJobByIdAsync(long jobId, CancellationToken ct)
    {
        var job = await _dbContext.Jobs.AsNoTracking().FirstOrDefaultAsync(j => j.Id == jobId, ct);

        if (job is null)
            return Result<JobResponseDto>.Failure(JobError.NotFound);

        return Result<JobResponseDto>.Success(
            new JobResponseDto(job.Id, job.Status.ToString(), job.CreatedAt, job.RunAt)
        );
    }
}

public record PagedResultDto<T>(IReadOnlyList<T> Items, int TotalCount, int Page, int PageSize);
