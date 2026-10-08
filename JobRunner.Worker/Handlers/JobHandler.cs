using System.Text.Json;
using JobRunner.Infrastructure.Data;
using Microsoft.Extensions.Logging;

namespace JobRunner.Worker.Handlers;

public record SendEmailPayload(string To, string Subject, string Body);

public class SendEmailJobHandler : IJobHandler
{
    private readonly ILogger<SendEmailJobHandler> _logger;
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true
    };

    public string JobType => "SendEmail";

    public SendEmailJobHandler(ILogger<SendEmailJobHandler> logger)
    {
        _logger = logger;
    }

    public async Task ExecuteAsync(ClaimedJob job, CancellationToken ct)
    {
        var payload = JsonSerializer.Deserialize<SendEmailPayload>(job.Payload, JsonOptions)
            ?? throw new InvalidOperationException("Failed to deserialize SendEmail payload.");

        _logger.LogInformation(
            "Sending email to {To} with subject '{Subject}' (Job ID: {JobId})",
            payload.To,
            payload.Subject,
            job.Id
        );

        // Simulate work (e.g., SMTP call or external API request)
        await Task.Delay(1000, ct);
    }
}
