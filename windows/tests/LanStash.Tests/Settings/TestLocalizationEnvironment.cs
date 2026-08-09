using System.Runtime.CompilerServices;
using System.Xml.Linq;
using LanStash.App.Localization;
using LanStash.Domain;

namespace LanStash.Tests.Settings;

internal static class TestLocalizationEnvironment
{
#pragma warning disable CA2255 // 测试程序集需要在任何测试类型初始化前安装无 WinUI 宿主的平台替身。
    [ModuleInitializer]
    internal static void Initialize()
    {
        var service = new LocalizationService(
            new MemoryLanguagePreferenceStore(),
            new TestLocalizationPlatform());
        service.Initialize();
        LocalizationService.UseForTests(service);
    }
#pragma warning restore CA2255
}

internal sealed class TestLocalizationPlatform : ILocalizationPlatform
{
    private readonly IReadOnlyDictionary<string, string> _resources = LoadResources();

    public string? SystemLanguage => "en-US";

    public void ApplyLanguage(string language)
    {
    }

    public string? GetString(string key) =>
        _resources.TryGetValue(key, out var value) ? value : null;

    private static IReadOnlyDictionary<string, string> LoadResources()
    {
        var path = FindRepositoryFile(
            "windows/src/LanStash.App/Strings/en-US/Resources.resw");
        return XDocument.Load(path)
            .Descendants("data")
            .Select(element => new
            {
                Name = (string?)element.Attribute("name"),
                Value = (string?)element.Element("value"),
            })
            .Where(item => !string.IsNullOrEmpty(item.Name) && item.Value is not null)
            .ToDictionary(
                item => item.Name!,
                item => item.Value!,
                StringComparer.Ordinal);
    }

    private static string FindRepositoryFile(string relativePath)
    {
        var directory = new DirectoryInfo(Directory.GetCurrentDirectory());
        while (directory is not null)
        {
            var candidate = Path.Combine(directory.FullName, relativePath);
            if (File.Exists(candidate))
            {
                return candidate;
            }
            directory = directory.Parent;
        }
        throw new DirectoryNotFoundException(
            $"Unable to locate repository file: {relativePath}");
    }
}

internal sealed class MemoryLanguagePreferenceStore : ILanguagePreferenceStore
{
    public AppLanguageSelection? Load() => null;
    public bool Save(AppLanguageSelection selection) => true;
}
