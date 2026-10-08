using System.Text.Json;

namespace JobRunner.Api.DTOs;

public record JobRequestDto(string JobType, JsonElement Payload);
