using LanStash.App.Features.Settings;
using LanStash.Domain;

namespace LanStash.Tests.Settings;

public sealed class AppSettingsServiceTests
{
    [Fact]
    public void CorruptLocalValueFallsBackToSafeDefaults()
    {
        var directory = Directory.CreateTempSubdirectory("lanstash-settings-");
        try
        {
            var path = Path.Combine(directory.FullName, "settings.json");
            File.WriteAllText(path, "{not-json");

            var preferences = new FileAppSettingsStore(path).Load();

            Assert.Equal(AppThemePreference.System, preferences.Theme);
            Assert.Empty(preferences.HiddenOptionalModules);
        }
        finally
        {
            directory.Delete(recursive: true);
        }
    }

    [Fact]
    public void OnlyOptionalModulesCanBeHiddenAndPreferencePersists()
    {
        var store = new MemoryStore(AppSettingsPreferences.Default);
        var service = new AppSettingsService(store);

        service.SetModuleVisible(AppModule.Files, false);
        service.SetModuleVisible(AppModule.Chat, false);
        service.SetModuleVisible(AppModule.Downloads, false);
        service.SetTheme(AppThemePreference.Dark);

        Assert.True(service.IsModuleVisible(AppModule.Files));
        Assert.True(service.IsModuleVisible(AppModule.Chat));
        Assert.False(service.IsModuleVisible(AppModule.Downloads));
        Assert.Equal(AppThemePreference.Dark, store.Saved.Theme);
        Assert.Single(store.Saved.HiddenOptionalModules);
        Assert.Contains(AppModule.Downloads, store.Saved.HiddenOptionalModules);
    }

    [Fact]
    public void ModuleVisibilityChangeIsDistinguishedFromThemeChange()
    {
        var service = new AppSettingsService(new MemoryStore(AppSettingsPreferences.Default));
        var changes = new List<bool>();
        service.Changed += (_, change) => changes.Add(change.ModuleVisibilityChanged);

        service.SetTheme(AppThemePreference.Light);
        service.SetModuleVisible(AppModule.Containers, false);

        Assert.Equal([false, true], changes);
    }

    [Fact]
    public void UnauthorizedLoadFallsBackToDefaults()
    {
        var service = new AppSettingsService(new UnauthorizedLoadStore());

        Assert.Equal(AppSettingsPreferences.Default, service.Preferences);
    }

    [Fact]
    public void ThrowingSaveDoesNotPublishThemeOrModuleChanges()
    {
        var service = new AppSettingsService(new ThrowingSaveStore());
        var changedCount = 0;
        service.Changed += (_, _) => changedCount++;

        var themeSaved = service.SetTheme(AppThemePreference.Dark);
        var moduleSaved = service.SetModuleVisible(AppModule.Downloads, false);

        Assert.False(themeSaved);
        Assert.False(moduleSaved);
        Assert.Equal(AppThemePreference.System, service.Preferences.Theme);
        Assert.True(service.IsModuleVisible(AppModule.Downloads));
        Assert.Equal(0, changedCount);
    }

    [Fact]
    public async Task CacheCoordinatorClearsOnlyRegisteredParticipants()
    {
        var coordinator = new RegenerableCacheCoordinator();
        var active = new CacheParticipant("photos", new(3, 120));
        var removed = new CacheParticipant("removed", new(5, 500));
        using var activeRegistration = coordinator.Register(active);
        var removedRegistration = coordinator.Register(removed);
        removedRegistration.Dispose();

        var before = coordinator.Snapshot();
        var result = await coordinator.ClearAsync();

        Assert.Equal(new RegenerableCacheSummary(3, 120), before);
        Assert.True(result.IsComplete);
        Assert.Equal(1, result.ClearedParticipants);
        Assert.Equal(1, active.ClearCount);
        Assert.Equal(0, removed.ClearCount);
        Assert.Equal(new RegenerableCacheSummary(), result.Summary);
    }

    private sealed class MemoryStore(AppSettingsPreferences preferences) : IAppSettingsStore
    {
        public AppSettingsPreferences Saved { get; private set; } = preferences;
        public AppSettingsPreferences Load() => Saved;
        public bool Save(AppSettingsPreferences value)
        {
            Saved = value;
            return true;
        }
    }

    private sealed class UnauthorizedLoadStore : IAppSettingsStore
    {
        public AppSettingsPreferences Load() => throw new UnauthorizedAccessException();
        public bool Save(AppSettingsPreferences value) => true;
    }

    private sealed class ThrowingSaveStore : IAppSettingsStore
    {
        public AppSettingsPreferences Load() => AppSettingsPreferences.Default;
        public bool Save(AppSettingsPreferences value) => throw new IOException();
    }

    private sealed class CacheParticipant(
        string id,
        RegenerableCacheSummary summary) : IRegenerableCacheParticipant
    {
        private RegenerableCacheSummary _summary = summary;
        public string CacheId => id;
        public int ClearCount { get; private set; }
        public RegenerableCacheSummary Snapshot() => _summary;
        public Task ClearAsync(CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            ClearCount++;
            _summary = new RegenerableCacheSummary();
            return Task.CompletedTask;
        }
    }
}
