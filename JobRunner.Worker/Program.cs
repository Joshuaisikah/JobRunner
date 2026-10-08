using JobRunner.Infrastructure.Data;
using JobRunner.Worker;
using JobRunner.Worker.Handlers;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

var builder = Host.CreateApplicationBuilder(args);

builder.Services.AddDbContext<JobRunnerDbContext>(options =>
    options.UseNpgsql(builder.Configuration["ConnectionStrings:Default"])
);
builder.Services.AddScoped<JobStore>();
builder.Services.AddHostedService<JobWorker>();
builder.Services.AddScoped<IJobHandler, SendEmailJobHandler>();
builder.Services.AddScoped<IJobHandler, ResizeImageJobHandler>();

builder.Build().Run();
