using JobRunner.Infrastructure.Data;
using Microsoft.EntityFrameworkCore;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddDbContext<JobRunnerDbContext>(options =>
    options.UseNpgsql(builder.Configuration.GetConnectionString("Default"))
);
var app = builder.Build();

app.Run();
