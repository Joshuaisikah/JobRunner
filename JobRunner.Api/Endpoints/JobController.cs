using JobRunner.Api.DTOs;
using JobRunner.Api.Services;
using JobRunner.Infrastructure.Data;
using Microsoft.AspNetCore.Mvc;

namespace JobRunner.Api.Endpoints;

[ApiController]
[Route("api/jobs")]
public class JobController : ControllerBase
{
    private readonly JobService _jobService;

    public JobController(JobService jobService)
    {
        _jobService = jobService;
    }

    [HttpPost]
    public async Task<IActionResult> CreateJob(
        [FromBody] JobRequestDto jobRequest,
        CancellationToken ct
    )
    {
        var result = await _jobService.CreateJobAsync(jobRequest, ct);
        if (result.IsSuccess)
            return CreatedAtAction(nameof(GetJob), new { id = result.Value.Id }, result.Value);
        return BadRequest(result.Error.ToString());
    }

    [HttpGet("{id}")]
    public async Task<IActionResult> GetJob(long id, CancellationToken ct)
    {
        var job = await _jobService.GetJobByIdAsync(id, ct);
        if (!job.IsSuccess)
            return NotFound();
        return Ok(job.Value);
    }

    [HttpGet]
    public async Task<IActionResult> GetJobs(
        [FromQuery] JobStatus? status,
        [FromQuery] int page = 1,
        [FromQuery] int pageSize = 20,
        CancellationToken ct = default
    )
    {
        var result = await _jobService.GetJobsAsync(status, page, pageSize, ct);
        return Ok(result);
    }
}
