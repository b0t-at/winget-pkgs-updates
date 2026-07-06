using FluentAssertions;
using WingetMaintainer.Core.Urls;
using Xunit;

namespace WingetMaintainer.Core.Tests.Urls;

public sealed class UrlTemplateEngineTests
{
    [Fact]
    public void Expand_SimpleVersion_ReplacesAndHasNoArchitecture()
    {
        string template = "https://github.com/o/r/releases/download/v{VERSION}/x-{VERSION}.zip";

        IReadOnlyList<InstallerUrl> result = UrlTemplateEngine.Expand(
            template,
            new UrlTemplateValues("1.2.3")
        );

        result.Should().ContainSingle();
        result[0].Url.Should().Be("https://github.com/o/r/releases/download/v1.2.3/x-1.2.3.zip");
        result[0].Architecture.Should().BeNull();
    }

    [Fact]
    public void Expand_MultipleUrlsWithArchitectureSuffix_ParsesEachArchitecture()
    {
        // JGraph.Draw-style: space separated, each with a |arch suffix.
        string template =
            "https://host/draw-ia32-{VERSION}.exe|x86 "
            + "https://host/draw-{VERSION}.exe|x64 "
            + "https://host/draw-arm64-{VERSION}.exe|arm64";

        IReadOnlyList<InstallerUrl> result = UrlTemplateEngine.Expand(
            template,
            new UrlTemplateValues("27.0.0")
        );

        result.Should().HaveCount(3);
        result.Select(installer => installer.Architecture).Should().Equal("x86", "x64", "arm64");
        result[1].Url.Should().Be("https://host/draw-27.0.0.exe");
    }

    [Fact]
    public void Expand_TagAndArpVersion_ReplacesBothTokens()
    {
        // icsharpcode.ILSpy-style: {TAG} and {ARPVERSION} distinct from {VERSION}.
        string template =
            "https://github.com/icsharpcode/ILSpy/releases/download/{TAG}/ILSpy_Installer_{ARPVERSION}-x64.msi "
            + "https://github.com/icsharpcode/ILSpy/releases/download/{TAG}/ILSpy_Installer_{ARPVERSION}-arm64.msi";

        UrlTemplateValues values = new(Version: "9.1", Tag: "v9.1", ArpVersion: "9.1.0.7988");

        IReadOnlyList<InstallerUrl> result = UrlTemplateEngine.Expand(template, values);

        result.Should().HaveCount(2);
        result[0]
            .Url.Should()
            .Be(
                "https://github.com/icsharpcode/ILSpy/releases/download/v9.1/ILSpy_Installer_9.1.0.7988-x64.msi"
            );
        result[0].Architecture.Should().BeNull();
    }

    [Fact]
    public void Expand_TemplateUsesTagButNoValue_Throws()
    {
        string template = "https://host/{TAG}/file.zip";

        Action act = () => UrlTemplateEngine.Expand(template, new UrlTemplateValues("1.0.0"));

        act.Should().Throw<InvalidOperationException>().WithMessage("*{TAG}*");
    }
}
