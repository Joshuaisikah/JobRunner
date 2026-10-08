using JobRunner.Api.Services;
using JobRunner.Infrastructure.Data;
using Microsoft.EntityFrameworkCore;
using Scalar.AspNetCore;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddDbContext<JobRunnerDbContext>(options =>
    options.UseNpgsql(builder.Configuration.GetConnectionString("Default"))
);

builder.Services.AddControllers();
builder.Services.AddOpenApi();

builder.Services.AddScoped<JobService>();

var app = builder.Build();

app.MapOpenApi(); // ← exposes the OpenAPI JSON Scalar reads from

app.MapScalarApiReference(options =>
{
    options.WithTheme(ScalarTheme.DeepSpace); // ← pick your theme
});
app.MapControllers();

app.Run();
