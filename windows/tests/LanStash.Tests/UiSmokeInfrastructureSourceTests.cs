namespace LanStash.Tests;

public sealed class UiSmokeInfrastructureSourceTests
{
    [Fact]
    public void SmokePreferencesAreInMemoryWithoutChangingProductionStores()
    {
        var settings = Read("windows/src/LanStash.App/Features/Settings/AppSettingsService.cs");
        var localization = Read("windows/src/LanStash.App/Localization/LocalizationService.cs");
        Assert.Contains("#if LANSTASH_UI_SMOKE", settings);
        Assert.Contains("new(new SmokePreferenceStore())", settings);
        Assert.Contains("#else\n    public static AppSettingsService Current { get; } = new(new FileAppSettingsStore());", settings);
        Assert.Contains("#if LANSTASH_UI_SMOKE\n        return new SmokeLanguageStore();", localization);
        Assert.Contains("new FileLanguagePreferenceStore(Path.Combine(", localization);
        Assert.Contains("\"LanStash\", \"language.txt\"", localization);
    }

    [Fact]
    public void FullRunRecordsFailuresWithoutTurningThemIntoSuccess()
    {
        var runner = Read("windows/tests/UiSmoke/run.ps1");
        Assert.Contains("[switch]$ContinueOnFailure", runner);
        Assert.Contains("if (-not $ContinueOnFailure) { throw }", runner);
        Assert.Contains("status='failed'", runner);
        Assert.Contains("status='passed'", runner);
        Assert.Contains("$case[0] + '-' + $label", runner);
        Assert.Contains("results.json", runner);
        Assert.Contains("if ($failedCount -gt 0) { throw", runner);
        Assert.Contains("$complete.LastWriteTime -lt $started", runner);
        Assert.Contains("$process.Kill(); $process.WaitForExit()", runner);
    }

    private static string Read(string relativePath)
    {
        for (var directory = new DirectoryInfo(AppContext.BaseDirectory); directory is not null; directory = directory.Parent)
        {
            var path = Path.Combine(directory.FullName, relativePath);
            if (File.Exists(path)) return File.ReadAllText(path).Replace("\r\n", "\n");
        }
        throw new FileNotFoundException(relativePath);
    }
}
