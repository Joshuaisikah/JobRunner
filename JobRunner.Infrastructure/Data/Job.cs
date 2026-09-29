namespace JobRunner.Infrastructure.Data;

public class Job
{
    public long Id { get; set; }
    public required string JobType { get; set; }
    public required string Payload { get; set; }

    public JobStatus Status { get; set; }
    public int Attempts { set; get; }
    public string? LastError { get; set; }
    public DateTime RunAt { get; set; }
    public DateTime CreatedAt { get; set; }
    public string? LockedBy { get; set; }
    public DateTime? ClaimedAt { get; set; }
    public int FenceToken { get; set; }
}
