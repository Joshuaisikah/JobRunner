using System.ComponentModel.DataAnnotations;
using System.Text.Json;

namespace JobRunner.Api.DTOs;

public record JobRequestDto(
    [Required] string JobType,
    // Must be a JSON object/array. A bare string/number/null will be rejected by validation.
    [Required] JsonElement Payload,
    // Optional. When present it must be UTC (the binder + validation enforce this).
    DateTime? RunAt = null,
    // Optional per-job override. Default is applied in the service if null.
    [Range(1, 100)] int? MaxAttempts = null
);
