using Microsoft.EntityFrameworkCore;

namespace JobRunner.Infrastructure.Data;

public record ClaimedJob(
    long Id,
    string JobType,
    string Payload,
    int FenceToken,
    int Attempts,
    int MaxAttempts
);

public class JobStore(JobRunnerDbContext db)
{
    public async Task<List<ClaimedJob>> ClaimAsync(string workerId, int batch, CancellationToken ct)
    {
        var now = DateTime.UtcNow;
        return await db
            .Database.SqlQuery<ClaimedJob>(
                $"""
                UPDATE jobs
                SET "Status" = 'Running', "LockedBy" = {workerId}, "ClaimedAt" = {now},
                    "FenceToken" = "FenceToken" + 1, "Attempts" = "Attempts" + 1
                WHERE "Id" IN (
                    SELECT "Id" FROM jobs
                    WHERE "Status" = 'Pending' AND "RunAt" <= {now}
                    ORDER BY "RunAt", "Id"
                    LIMIT {batch}
                    FOR UPDATE SKIP LOCKED)
                RETURNING "Id", "JobType", "Payload"::text AS "Payload",
                          "FenceToken", "Attempts", "MaxAttempts"
                """
            )
            .ToListAsync(ct);
    }

    // true = my write landed, false = I lost the claim (zero rows matched)
    public async Task<bool> CompleteAsync(long id, int token, CancellationToken ct)
    {
        var rows = await db.Database.ExecuteSqlInterpolatedAsync(
            $"""
            UPDATE jobs SET "Status" = 'Succeeded', "LockedBy" = NULL, "LastError" = NULL
            WHERE "Id" = {id} AND "FenceToken" = {token} AND "Status" = 'Running'
            """,
            ct
        );
        return rows == 1;
    }

    public async Task<bool> FailAsync(
        ClaimedJob job,
        string error,
        bool permanent,
        CancellationToken ct
    )
    {
        var terminal = permanent || job.Attempts >= job.MaxAttempts;
        var backoff = TimeSpan.FromSeconds(Math.Pow(2, job.Attempts - 1)); // 1s,2s,4s,8s,16s
        var runAt = DateTime.UtcNow + backoff;
        var status = terminal ? "Failed" : "Pending";

        var rows = await db.Database.ExecuteSqlInterpolatedAsync(
            $"""
            UPDATE jobs
            SET "Status" = {status}, "RunAt" = {runAt}, "LastError" = {error}, "LockedBy" = NULL
            WHERE "Id" = {job.Id} AND "FenceToken" = {job.FenceToken} AND "Status" = 'Running'
            """,
            ct
        );
        return rows == 1;
    }
}
