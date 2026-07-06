using FluentAssertions;
using WingetMaintainer.Core.Submission;
using Xunit;

namespace WingetMaintainer.Core.Tests.Submission;

public sealed class SubmitServiceTests
{
    private static SubmitOptions Options(SubmissionTool tool = SubmissionTool.Komac) =>
        new()
        {
            ManifestPath = @"C:\manifests\c\Contoso\App\1.0.0",
            PackageId = "Contoso.App",
            Version = "1.0.0",
            Token = "SECRET-TOKEN",
            Tool = tool,
        };

    [Fact]
    public void BuildCommand_Komac_ProducesSubmitArguments()
    {
        (string fileName, IReadOnlyList<string> arguments) = SubmitService.BuildCommand(Options());

        fileName.Should().Be("komac");
        arguments
            .Should()
            .Equal(
                "submit",
                @"C:\manifests\c\Contoso\App\1.0.0",
                "--yes",
                "--token",
                "SECRET-TOKEN"
            );
    }

    [Fact]
    public void BuildCommand_KomacWithResolves_AppendsResolves()
    {
        SubmitOptions options = Options() with { Resolves = "12345" };

        (_, IReadOnlyList<string> arguments) = SubmitService.BuildCommand(options);

        arguments.Should().ContainInOrder("--resolves", "12345");
    }

    [Fact]
    public void BuildCommand_WinGetCreate_UsesDefaultPrTitle()
    {
        (string fileName, IReadOnlyList<string> arguments) = SubmitService.BuildCommand(
            Options(SubmissionTool.WinGetCreate)
        );

        fileName.Should().Be("wingetcreate");
        arguments
            .Should()
            .Equal(
                "submit",
                "--prtitle",
                "Update version: Contoso.App version 1.0.0",
                "-t",
                "SECRET-TOKEN",
                @"C:\manifests\c\Contoso\App\1.0.0"
            );
    }

    [Fact]
    public void BuildCommand_WinGetCreateWithExplicitTitle_UsesProvidedTitle()
    {
        SubmitOptions options = Options(SubmissionTool.WinGetCreate) with
        {
            PrTitle = "Custom title",
        };

        (_, IReadOnlyList<string> arguments) = SubmitService.BuildCommand(options);

        arguments.Should().ContainInOrder("--prtitle", "Custom title");
    }

    [Fact]
    public void BuildCommand_MissingToken_Throws()
    {
        SubmitOptions options = Options() with { Token = "" };

        Action act = () => SubmitService.BuildCommand(options);

        act.Should().Throw<ArgumentException>();
    }
}
