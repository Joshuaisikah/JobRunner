namespace JobRunner.Api.DTOs;

public record JobResponseDto(long Id, string Status, DateTime CreatedAt, DateTime RunAt);
