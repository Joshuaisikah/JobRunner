namespace JobRunner.Infrastructure;

public class Result<T>
{
    public bool IsSuccess { get; }
    public T? Value { get; }
    public JobError? Error { get; }

    private Result(bool isSuccess, T? value, JobError? error)
    {
        IsSuccess = isSuccess;
        Value = value;
        Error = error;
    }

    public static Result<T> Success(T value) => new(true, value, null);

    public static Result<T> Failure(JobError error) => new(false, default, error);
}
