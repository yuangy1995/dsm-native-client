using LanStash.App.Features.Chat;
using System.Xml.Linq;

namespace LanStash.Tests;

public sealed class ApplicationAssemblyBoundaryTests
{
    [Fact]
    public void UnitTestsLoadApplicationLogicWithoutWinUiExecutable()
    {
        Assert.Equal(
            "LanStash.Application",
            typeof(ChatBrowserViewModel).Assembly.GetName().Name);

        var testsProject = ReadRepositoryFile(
            "windows/tests/LanStash.Tests/LanStash.Tests.csproj");
        Assert.Contains(
            "LanStash.Application\\LanStash.Application.csproj",
            testsProject,
            StringComparison.Ordinal);
        Assert.DoesNotContain(
            "LanStash.App\\LanStash.App.csproj",
            testsProject,
            StringComparison.Ordinal);
    }

    [Fact]
    public void ApplicationLogicProjectHasOneWayReferencesAndMirroredCompileOwnership()
    {
        var applicationProject = ReadRepositoryFile(
            "windows/src/LanStash.Application/LanStash.Application.csproj");

        Assert.DoesNotContain("<UseWinUI>true</UseWinUI>", applicationProject);
        Assert.DoesNotContain("<OutputType>WinExe</OutputType>", applicationProject);
        Assert.Contains("LanStash.Domain\\LanStash.Domain.csproj", applicationProject);
        Assert.DoesNotContain("LanStash.Infrastructure", applicationProject);

        var appProject = ReadRepositoryFile(
            "windows/src/LanStash.App/LanStash.App.csproj");
        Assert.Contains(
            "LanStash.Application\\LanStash.Application.csproj",
            appProject,
            StringComparison.Ordinal);
        Assert.Equal(
            ApplicationCompilePatterns(applicationProject),
            AppRemovedCompilePatterns(appProject));
    }

    private static string[] ApplicationCompilePatterns(string project) =>
        XDocument.Parse(project)
            .Descendants("Compile")
            .Select(element => (string?)element.Attribute("Include"))
            .Where(value => value is not null)
            .Select(value => value!.Replace(
                "..\\LanStash.App\\",
                string.Empty,
                StringComparison.Ordinal))
            .Order(StringComparer.Ordinal)
            .ToArray();

    private static string[] AppRemovedCompilePatterns(string project) =>
        XDocument.Parse(project)
            .Descendants("Compile")
            .Select(element => (string?)element.Attribute("Remove"))
            .Where(value => value is not null)
            .Select(value => value!)
            .Order(StringComparer.Ordinal)
            .ToArray();

    private static string ReadRepositoryFile(string relativePath)
    {
        var directory = new DirectoryInfo(Directory.GetCurrentDirectory());
        while (directory is not null)
        {
            var candidate = Path.Combine(directory.FullName, relativePath);
            if (File.Exists(candidate))
            {
                return File.ReadAllText(candidate);
            }
            directory = directory.Parent;
        }
        throw new DirectoryNotFoundException(
            $"Unable to locate repository file: {relativePath}");
    }
}
