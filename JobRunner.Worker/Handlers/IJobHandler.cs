using JobRunner.Infrastructure.Data;

namespace JobRunner.Worker.Handlers;

public interface IJobHandler
{
    string JobType { get; }
    Task ExecuteAsync(ClaimedJob claimedJob, CancellationToken cancellationToken);
}
