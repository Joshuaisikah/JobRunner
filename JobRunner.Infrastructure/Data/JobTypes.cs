namespace JobRunner.Infrastructure.Data;

public static class JobType
{
    public const string SendEmail = "SendEmail";
    public const string ResizeImage = "ResizeImage";

    public static readonly string[] All = [SendEmail, ResizeImage];
}
