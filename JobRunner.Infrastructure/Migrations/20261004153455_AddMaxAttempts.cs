using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace JobRunner.Infrastructure.Migrations
{
    /// <inheritdoc />
    public partial class AddMaxAttempts : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<int>(
                name: "MaxAttempts",
                table: "jobs",
                type: "integer",
                nullable: false,
                defaultValue: 5);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropColumn(
                name: "MaxAttempts",
                table: "jobs");
        }
    }
}
