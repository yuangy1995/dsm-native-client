using LanStash.App.Localization;
using LanStash.Domain;

namespace LanStash.Tests.Settings;

public sealed class LocalizationServiceTests
{
    [Fact]
    public void UnauthorizedPreferenceLoadFallsBackToSystemLanguage()
    {
        var service = new LocalizationService(
            new UnauthorizedLoadStore(),
            new TestLocalizationPlatform());

        service.Initialize();

        Assert.Equal(AppLanguageSelection.System, service.Selection);
    }

    [Fact]
    public void ThrowingWriteDoesNotPublishOrChangeLanguage()
    {
        var service = new LocalizationService(
            new ThrowingSaveStore(),
            new TestLocalizationPlatform());
        service.Initialize();
        var changedCount = 0;
        service.LanguageChanged += (_, _) => changedCount++;

        var saved = service.TrySetSelection(AppLanguageSelection.SimplifiedChinese);

        Assert.False(saved);
        Assert.Equal(AppLanguageSelection.System, service.Selection);
        Assert.Equal(0, changedCount);
    }

    private sealed class UnauthorizedLoadStore : ILanguagePreferenceStore
    {
        public AppLanguageSelection? Load() => throw new UnauthorizedAccessException();
        public bool Save(AppLanguageSelection selection) => true;
    }

    private sealed class ThrowingSaveStore : ILanguagePreferenceStore
    {
        public AppLanguageSelection? Load() => null;
        public bool Save(AppLanguageSelection selection) => throw new IOException();
    }
}
