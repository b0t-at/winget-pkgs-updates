using FluentAssertions;
using WingetMaintainer.Core.Validation;
using Xunit;

namespace WingetMaintainer.Core.Tests.Validation;

public sealed class SandboxValidationServiceTests
{
    [Fact]
    public void BuildCommand_WithManifestPath_UsesManifestPathSwitch()
    {
        SandboxValidationOptions options = new()
        {
            ScriptPath = @"C:\scripts\Test-Manifest-Sandbox.ps1",
            ManifestPath = @"C:\manifests\app",
        };

        (string fileName, IReadOnlyList<string> arguments) = SandboxValidationService.BuildCommand(options);

        fileName.Should().Be("pwsh");
        arguments.Should().ContainInOrder("-File", @"C:\scripts\Test-Manifest-Sandbox.ps1");
        arguments.Should().ContainInOrder("-ManifestPath", @"C:\manifests\app");
        arguments.Should().NotContain("-ManifestURL");
    }

    [Fact]
    public void BuildCommand_WithManifestUrl_UsesManifestUrlSwitch()
    {
        SandboxValidationOptions options = new()
        {
            ScriptPath = @"C:\scripts\Test-Manifest-Sandbox.ps1",
            ManifestUrl = "https://example.com/manifest",
        };

        (_, IReadOnlyList<string> arguments) = SandboxValidationService.BuildCommand(options);

        arguments.Should().ContainInOrder("-ManifestURL", "https://example.com/manifest");
        arguments.Should().NotContain("-ManifestPath");
    }

    [Fact]
    public void BuildCommand_BothProvided_Throws()
    {
        SandboxValidationOptions options = new()
        {
            ScriptPath = "script.ps1",
            ManifestPath = @"C:\manifests\app",
            ManifestUrl = "https://example.com/manifest",
        };

        Action act = () => SandboxValidationService.BuildCommand(options);

        act.Should().Throw<InvalidOperationException>();
    }

    [Fact]
    public void BuildCommand_NeitherProvided_Throws()
    {
        SandboxValidationOptions options = new() { ScriptPath = "script.ps1" };

        Action act = () => SandboxValidationService.BuildCommand(options);

        act.Should().Throw<InvalidOperationException>();
    }
}
