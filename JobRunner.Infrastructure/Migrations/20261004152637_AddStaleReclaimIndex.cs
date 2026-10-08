using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace JobRunner.Infrastructure.Migrations
{
    /// <inheritdoc />
    public partial class AddStaleReclaimIndex : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.CreateIndex(
                name: "IX_jobs_stale",
                table: "jobs",
                columns: new[] { "ClaimedAt", "Id" },
                filter: "\"Status\" = 'Running'");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropIndex(
                name: "IX_jobs_stale",
                table: "jobs");
        }
    }
}
