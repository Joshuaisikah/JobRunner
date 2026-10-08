using JobRunner.Infrastructure.Data;
using JobRunner.Worker;
using Microsoft.EntityFrameworkCore;

var builder = Host.CreateApplicationBuilder(args);

builder.Services.AddDbContext<JobRunnerDbContext>(options =>
    options.UseNpgsql(builder.Configuration.GetConnectionString("Default")));
builder.Services.AddScoped<JobStore>();
builder.Services.AddHostedService<JobWorker>();

builder.Build().Run();
