# JobRunner

A generic background job system (project 06 of the .NET ladder). Jobs are rows in
PostgreSQL. Any number of worker processes claim and run them. With N workers running at
once, no job runs twice, a crashed worker's jobs are recovered, and a worker that wakes up
late cannot overwrite the result of the worker that replaced it.

No Hangfire, Quartz or MassTransit. The claiming, leasing and fencing are hand-written SQL in
`JobRunner.Infrastructure/Data/JobStore.cs`.

## Projects

| Project | What it is |
|---|---|
| `JobRunner.Api` | ASP.NET Core API. Enqueues jobs and lists them. Owns the connection string used for migrations. |
| `JobRunner.Infrastructure` | EF Core `DbContext`, the `Job` entity, migrations, and `JobStore` (all claim/complete/fail/heartbeat SQL). |
| `JobRunner.Worker` | Generic-host console app. One `BackgroundService` (`JobWorker`) that claims, runs, heartbeats and reclaims. Run as many copies as you like. |

```
            POST /api/jobs                      claim / heartbeat / complete / fail
  client ─────────────────▶  Api  ──INSERT──▶  ┌──────────────┐  ◀──────────────  Worker 1
                                               │  jobs table  │  ◀──────────────  Worker 2
                                               │  (Postgres)  │  ◀──────────────  Worker 3
                                               └──────────────┘
```

The API and the workers never talk to each other. The `jobs` table is the only shared state,
so every guarantee below is enforced by the database, not by C#.

## Setup

```bash
docker compose up -d                       # Postgres 17 on localhost:5433
./project-tools.sh migrate                 # apply EF Core migrations
./project-tools.sh run                     # API on http://localhost:5200 (Scalar UI at /scalar)
dotnet run --project JobRunner.Worker      # one worker; start more in other terminals
```

The brief asks for `dotnet run --worker`. I used a separate `JobRunner.Worker` project
instead, so the API and the workers can be scaled and killed independently.

## API

| Method & route | Result |
|---|---|
| `POST /api/jobs` | `201 Created` with a `Location` header. `400` for an unknown `jobType`, a payload that isn't a JSON object/array, or a non-UTC `runAt`. |
| `GET /api/jobs/{id}` | `200`, or `404` |
| `GET /api/jobs?status=Pending&page=1&pageSize=20` | Paged list, newest first (`CreatedAt DESC, Id DESC`). `pageSize` is capped at 100. |

Request body:

```json
{ "jobType": "SendEmail", "payload": { "to": "a@b.c", "subject": "hi", "body": "…" },
  "runAt": "2026-10-09T12:00:00Z", "maxAttempts": 5 }
```

`runAt` and `maxAttempts` are optional (defaults: now, 5). Job types: `SendEmail`,
`ResizeImage`. Both handlers are **simulated**: they log and `Task.Delay`, with no real side
effects. See "What I'd do next".

## How it works

### Job lifecycle

```
                 claim (RunAt <= now)                 complete (token matches)
   Pending ───────────────────────────▶ Running ─────────────────────────────▶ Succeeded
      ▲                                  │  │
      │  fail, attempts left             │  │ fail, permanent or attempts used up
      │  (RunAt = now + backoff)         │  └──────────────────────────────────▶ Failed
      └──────────────────────────────────┘
                                         │ lease goes stale (ClaimedAt too old)
                                         └──▶ reclaimed by another worker: Running again,
                                              new FenceToken, Attempts + 1
                                              (or Failed if attempts are used up)
```

### Columns that matter

| Column | Purpose |
|---|---|
| `Status` | `Pending` / `Running` / `Succeeded` / `Failed` |
| `RunAt` | Earliest time the job may be claimed. Also used for retry backoff. |
| `FenceToken` | Incremented on every claim and reclaim. Every write a worker makes afterwards has `WHERE "FenceToken" = <my token>`. |
| `ClaimedAt` | Set on claim **and refreshed by every heartbeat**. It's really "lease last renewed at". See "What I'd do next". |
| `LockedBy` | Worker ID. Informational only: it plays no part in the fence. |
| `Attempts` / `MaxAttempts` | Retry budget, per job. |
| `LastError` | The most recent error only. Earlier errors are overwritten. |

### Claiming

`ClaimAsync` is one statement: an `UPDATE ... WHERE "Id" IN (SELECT ... ORDER BY "RunAt", "Id"
LIMIT @batch FOR UPDATE SKIP LOCKED) RETURNING ...`. It moves up to 10 `Pending` jobs whose
`RunAt` has passed to `Running`, bumps `FenceToken` and `Attempts`, and returns them.

**Why two workers claiming in the same millisecond never get each other's rows** (my answers,
from the Q&A on 9 Oct):

- **`FOR UPDATE`** puts a row-level lock on each row the inner `SELECT` picks. Another
  transaction that tries to update or lock one of those rows blocks until A's transaction
  finishes. The lock lasts until the **transaction** ends, not until the `SELECT` ends.
- **Without `SKIP LOCKED`**, worker B would wait until A finishes. **With it**, B passes over
  A's locked rows and claims the next ones (11–20) without waiting.
- **It has to be one atomic statement.** If the `SELECT ... FOR UPDATE` and the `UPDATE` were two
  separate auto-committed statements, A's locks would be released between them. B could then find
  the same jobs still unlocked and Pending, and both workers would run them.

In one line: the row-level lock taken by `FOR UPDATE`, together with `SKIP LOCKED` and a single
atomic statement, means that when A has locked its rows, B skips them and takes different ones.

### Leases, heartbeat and stale reclaim

- Each worker heartbeats every **10s**, refreshing `ClaimedAt` for the jobs it holds, fenced by
  token (`HeartbeatAsync`). If a job is missing from the heartbeat's `RETURNING`, the worker
  has lost it and cancels that job's handler.
- Every **15s**, each worker runs `ReclaimStaleAsync`. A `Running` job whose `ClaimedAt` is
  older than **30s** either gets reclaimed (new token, `Attempts + 1`) or, if it has used up its
  attempts, is marked `Failed`.
- If two heartbeats in a row fail (e.g. the database is unreachable), the worker stops itself
  rather than keep running jobs it can no longer prove it owns.
- Timing rule, from `JobWorker.cs`: `BeatDeadline (3s) < HeartbeatInterval (10s) <= StaleTimeout (30s) / 3`.
  A worker can miss two heartbeats before its jobs become stealable.

### Fencing: why a hung worker can't overwrite the result

1. Worker A claims job 5 and gets token 1.
2. A freezes (GC pause, VM pause, SIGSTOP). Its heartbeat stops.
3. After 30s, worker B reclaims job 5. The token becomes 2. B runs it and completes it.
4. A wakes up and calls `CompleteAsync` with token 1. `WHERE "FenceToken" = 1` matches zero
   rows, so the write is a no-op. A logs "Lost fence token ownership" and moves on.

`CompleteAsync`, `FailAsync` and `HeartbeatAsync` all check the token.

### Retries

A failure that is not permanent sets the job back to `Pending` with
`RunAt = now + 2^(attempts-1)` seconds (1s, 2s, 4s, 8s, 16s). After `MaxAttempts`, or on a
permanent failure (e.g. no handler registered for the job type), it becomes `Failed`. A job
that runs past 60s is cancelled and counts as a retryable failure.

### Indexes

Both are **partial** indexes, matching the `WHERE` and `ORDER BY` of the query they serve:

| Index | Columns | Filter | Serves |
|---|---|---|---|
| `IX_jobs_claim` | `(RunAt, Id)` | `Status = 'Pending'` | `ClaimAsync` |
| `IX_jobs_stale` | `(ClaimedAt, Id)` | `Status = 'Running'` | `ReclaimStaleAsync` |

**Why the claim query's `ORDER BY` has to match the index** (my answers, from the Q&A on 9 Oct):

- **Without an index**, Postgres reads every row, checks for Pending, sorts them, and only then
  returns the first 10. That's all 1,000,000 rows, every time.
- **The index is a separate sorted copy** of `RunAt` and `Id`, where each entry points back to the
  full row. It's sorted by `RunAt`, and by `Id` when two `RunAt` values are equal.
- **When `ORDER BY RunAt, Id` matches the index**, Postgres starts at the front, walks forward in
  order, and stops after 10. There's no sort step, because the index already delivers rows in that
  order. That's about 10 entries instead of 1,000,000.
- **When the order doesn't match (`ORDER BY Id, RunAt`)**, it's like searching a phone book by first
  name: the `Id` values are scattered through an index sorted by `RunAt`. Postgres has to fall back
  to an explicit sort. And to sort, it must first find every matching row, so `LIMIT 10` can no
  longer stop early.
- **`Id` is in the index to make each position unique.** Two jobs with the same `RunAt` would
  otherwise come back in an unstable order. With `Id`, the order is fully determined and
  repeatable. Ties are common: every job scheduled for the same time ties on `RunAt`.
- **The index is partial (Pending only)**, so finished jobs never sit at the front for the walk to
  skip. With three workers, the last worker reads about 30 entries: it skips the 20 that the others
  have locked, and takes the next 10.

Still to learn: which `EXPLAIN` nodes show a match vs. a mismatch, and why the stale-reclaim query
needs its own index.

## Tests

The acceptance tests are bash scripts that start real worker processes against the real
database, then check both the `jobs` table and the worker logs. They are **not** `dotnet test`
(there is no xUnit project, so `./project-tools.sh test` does nothing useful yet).

```bash
docker compose up -d
./tests/acceptance.sh          # criteria 1 and 3–7, ~5 min; prints the checklist
./concurrency_loop.sh 20       # criterion 2: 20 consecutive runs of criterion 1, ~27 min
```

Logs go to `test-results/<suite>-<timestamp>/`. Exit codes: `0` pass, `1` fail, `2` environment
problem (DB down, stray worker running, build failed).

| # | Criterion | Script | How it's proved |
|---|---|---|---|
| 1 | 3 workers, 200 jobs → each executed exactly once | `concurrency_test.sh` | DB: every job `Attempts = 1`. Logs: every job ID in exactly one "Executing job" line across all workers, so a job claimed once but run twice still fails. |
| 2 | 20 runs, 20 passes | `concurrency_loop.sh` | Runs #1 N times |
| 3 | `kill -9` mid-job → re-run within stale timeout | `crash_test.sh` | SIGKILL worker A mid-handler, then worker B must reclaim no earlier than 30s and finish it |
| 4 | Hung worker can't write afterwards | `tests/hang_test.sh` | SIGSTOP A mid-job, B reclaims and completes, SIGCONT A. The row must still show B's result. |
| 5 | Job 60s ahead not claimed at t+10s | `tests/schedule_test.sh` | Still `Pending` at t+10 and t+50, and claimed no earlier than `runAt` |
| 6 | Claim query uses the intended index | `tests/explain_test.sh` | 50k seeded rows, `ANALYZE`, `EXPLAIN`: index scan on the partial index, no Sort, no Seq Scan |
| 7 | Nothing stuck in `Running` forever | `tests/outage_test.sh` | Stop the database mid-batch for 4s. Every job must end up terminal. |

`tests/explain_test.sh` copies the SQL from `JobStore`. If you change the claim or reclaim
query, change the test too, or it proves something about a query that no longer runs.

### Status

- Criteria 1 and 3–7: **pass** (`test-results/acceptance-20261009-185558`).
- Criterion 2: **20 / 20 passes** (`test-results/concurrency-20261009-190033`).

Both runs include the scope-lifetime fix in `ProcessJobAsync` and the graceful-shutdown fix
in the main loop's idle delay (12/12 clean shutdowns of an idle worker, up from 3/8).

## What I'd do next and why I didn't

**1. Fence the side effects, not just the table.** The fence token protects writes to `jobs`
and nothing else. If worker A hangs and B reclaims, both handlers run to completion. Today
that's harmless because the handlers are simulated. With real handlers it means two emails,
two charges, or A's resized image overwriting B's. There are two fixes: pass an
**idempotency key** to providers that support one (e.g. Stripe's `Idempotency-Key` header),
or use storage that supports **conditional writes** (compare-and-set / ETag `If-Match`), so a
stale writer is rejected. I didn't do this because there are no real side effects yet, and
idempotency is the whole of project 08.

**2. Split `ClaimedAt` into two columns.** It currently means both "when this attempt was
claimed" and "when the lease was last renewed", because the heartbeat overwrites it. Stale
reclaim needs the second meaning. Answering "how long did job X wait before it was claimed?"
needs the first, and right now `ClaimedAt − CreatedAt` gives the wrong answer for any job that
ran longer than one heartbeat. I'd rename it to a lease column (e.g. `LeaseRenewedAt`) and keep
the stale index on that. I didn't, because it's an observability problem and every acceptance
criterion passes without it.

**3. Keep attempt history in a `job_attempts` table.** The `jobs` row holds current state only.
Retries and reclaims overwrite `ClaimedAt`, `LockedBy` and `LastError`, so after attempt 3,
attempts 1 and 2 are gone. I'd add one row per attempt, keyed by `(job_id, fence_token)`,
inserted **in the same transaction as the claim** (so a crash between the two can't leave a
running job with no attempt row), and closed by complete/fail/reclaim. With that,
"why did job 9812 take 40 minutes?" becomes a query instead of a guess. It would also need a
retention policy, since it grows forever. I didn't build it because it's a schema change plus
four new tests, for a question none of the acceptance criteria asks.

**4. Structured logs with a job scope.** Logs carry the job ID as a parameter, but there's no
`ILogger.BeginScope` around a job's execution, so a handler's own log lines aren't
automatically tied to the job, attempt and token. I'd add a scope per attempt and,
eventually, OpenTelemetry traces.

**5. An xUnit project.** The acceptance scripts are the real proof, but they're slow and need
Docker. Fast tests for the backoff calculation and the API validation rules would catch
regressions in seconds.

**6. Keyset pagination for `GET /api/jobs`.** It uses `OFFSET`, which can skip or repeat rows
while workers are changing statuses between page requests. That's exactly what happens in this
system. I left it because the brief only asks for pagination, and keyset pagination comes up
properly in project 09.

**Optional items not built:** job priorities, cancellation, recurring/cron jobs, and a
per-type concurrency cap.
