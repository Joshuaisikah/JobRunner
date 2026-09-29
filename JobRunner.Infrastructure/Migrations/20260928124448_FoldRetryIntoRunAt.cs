using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace JobRunner.Infrastructure.Migrations
{
    /// <inheritdoc />
    public partial class FoldRetryIntoRunAt : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropColumn(
                name: "NextRetryAt",
                table: "jobs");

            migrationBuilder.CreateIndex(
                name: "IX_jobs_claim",
                table: "jobs",
                columns: new[] { "RunAt", "Id" },
                filter: "\"Status\" = 'Pending'");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropIndex(
                name: "IX_jobs_claim",
                table: "jobs");

            migrationBuilder.AddColumn<DateTime>(
                name: "NextRetryAt",
                table: "jobs",
                type: "timestamp with time zone",
                nullable: true);
        }
    }
}
