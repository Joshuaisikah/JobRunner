using System.Text.Json;
using JobRunner.Infrastructure.Data;
using Microsoft.Extensions.Logging;

namespace JobRunner.Worker.Handlers;

public record ResizeImagePayload(string ImageUrl, int Width, int Height);

public class ResizeImageJobHandler : IJobHandler
{
    private readonly ILogger<ResizeImageJobHandler> _logger;
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
    };

    public string JobType => Infrastructure.Data.JobType.ResizeImage;

    public ResizeImageJobHandler(ILogger<ResizeImageJobHandler> logger)
    {
        _logger = logger;
    }

    public async Task ExecuteAsync(ClaimedJob job, CancellationToken ct)
    {
        var payload =
            JsonSerializer.Deserialize<ResizeImagePayload>(job.Payload, JsonOptions)
            ?? throw new InvalidOperationException("Failed to deserialize ResizeImage payload.");

        _logger.LogInformation(
            "Resizing image {Url} to {Width}x{Height} (Job ID: {JobId})",
            payload.ImageUrl,
            payload.Width,
            payload.Height,
            job.Id
        );

        await Task.Delay(1500, ct); // Simulate processing
    }
}
