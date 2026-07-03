using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace WingetMaintainer.Data.Migrations
{
    /// <inheritdoc />
    public partial class InitialCreate : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.CreateTable(
                name: "PackageRuns",
                columns: table => new
                {
                    Id = table.Column<int>(type: "INTEGER", nullable: false)
                        .Annotation("Sqlite:Autoincrement", true),
                    PackageIdentifier = table.Column<string>(type: "TEXT", nullable: false),
                    Version = table.Column<string>(type: "TEXT", nullable: false),
                    ManifestHash = table.Column<string>(type: "TEXT", nullable: true),
                    Phase = table.Column<string>(type: "TEXT", nullable: false),
                    Outcome = table.Column<string>(type: "TEXT", nullable: false),
                    ManifestPath = table.Column<string>(type: "TEXT", nullable: true),
                    Error = table.Column<string>(type: "TEXT", nullable: true),
                    StartedAt = table.Column<DateTimeOffset>(type: "TEXT", nullable: false),
                    CompletedAt = table.Column<DateTimeOffset>(type: "TEXT", nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_PackageRuns", x => x.Id);
                });

            migrationBuilder.CreateTable(
                name: "Packages",
                columns: table => new
                {
                    Id = table.Column<string>(type: "TEXT", maxLength: 256, nullable: false),
                    Repo = table.Column<string>(type: "TEXT", nullable: false),
                    Url = table.Column<string>(type: "TEXT", nullable: false),
                    TagPattern = table.Column<string>(type: "TEXT", nullable: true),
                    With = table.Column<string>(type: "TEXT", nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_Packages", x => x.Id);
                });

            migrationBuilder.CreateTable(
                name: "StateEntries",
                columns: table => new
                {
                    PackageIdentifier = table.Column<string>(type: "TEXT", maxLength: 256, nullable: false),
                    Version = table.Column<string>(type: "TEXT", nullable: false),
                    ManifestHash = table.Column<string>(type: "TEXT", nullable: false),
                    State = table.Column<string>(type: "TEXT", nullable: false),
                    ValidationCount = table.Column<int>(type: "INTEGER", nullable: false),
                    InstallerHashes = table.Column<string>(type: "TEXT", nullable: false),
                    Description = table.Column<string>(type: "TEXT", nullable: false),
                    LastUpdated = table.Column<DateTimeOffset>(type: "TEXT", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_StateEntries", x => x.PackageIdentifier);
                });

            migrationBuilder.CreateTable(
                name: "ValidationJobs",
                columns: table => new
                {
                    Id = table.Column<int>(type: "INTEGER", nullable: false)
                        .Annotation("Sqlite:Autoincrement", true),
                    PackageRunId = table.Column<int>(type: "INTEGER", nullable: false),
                    PackageIdentifier = table.Column<string>(type: "TEXT", nullable: false),
                    ManifestPath = table.Column<string>(type: "TEXT", nullable: false),
                    Status = table.Column<string>(type: "TEXT", nullable: false),
                    Attempts = table.Column<int>(type: "INTEGER", nullable: false),
                    Host = table.Column<string>(type: "TEXT", nullable: true),
                    ExitCode = table.Column<int>(type: "INTEGER", nullable: true),
                    LogRef = table.Column<string>(type: "TEXT", nullable: true),
                    CreatedAt = table.Column<DateTimeOffset>(type: "TEXT", nullable: false),
                    StartedAt = table.Column<DateTimeOffset>(type: "TEXT", nullable: true),
                    CompletedAt = table.Column<DateTimeOffset>(type: "TEXT", nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_ValidationJobs", x => x.Id);
                    table.ForeignKey(
                        name: "FK_ValidationJobs_PackageRuns_PackageRunId",
                        column: x => x.PackageRunId,
                        principalTable: "PackageRuns",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateIndex(
                name: "IX_PackageRuns_PackageIdentifier",
                table: "PackageRuns",
                column: "PackageIdentifier");

            migrationBuilder.CreateIndex(
                name: "IX_ValidationJobs_PackageIdentifier",
                table: "ValidationJobs",
                column: "PackageIdentifier");

            migrationBuilder.CreateIndex(
                name: "IX_ValidationJobs_PackageRunId",
                table: "ValidationJobs",
                column: "PackageRunId");

            migrationBuilder.CreateIndex(
                name: "IX_ValidationJobs_Status",
                table: "ValidationJobs",
                column: "Status");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "Packages");

            migrationBuilder.DropTable(
                name: "StateEntries");

            migrationBuilder.DropTable(
                name: "ValidationJobs");

            migrationBuilder.DropTable(
                name: "PackageRuns");
        }
    }
}
