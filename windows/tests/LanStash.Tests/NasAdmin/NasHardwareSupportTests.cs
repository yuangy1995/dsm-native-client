using LanStash.Domain;
using LanStash.App.Features.NasAdmin;
using static LanStash.Tests.NasAdmin.NasHardwareReadTests;

namespace LanStash.Tests.NasAdmin;

public sealed class NasHardwareSupportTests
{
    [Fact]
    public async Task EditorCopiesAndPreservesSupportedModes()
    {
        using var f = new Fixture(); string[] modes = ["fullfan", "quietfan"];
        var value = (await f.Repository.LoadHardwareSettingsAsync()) with { SupportedFanModes = modes };
        using var model = new NasSettingsEditViewModel<NasHardwareSettings>();
        await model.ActivateAsync(f.Repository, "Synthetic", _ => Task.FromResult(value), (_, _) => throw new InvalidOperationException());
        Assert.Equal(modes, model.Draft!.SupportedFanModes); Assert.NotSame(modes, model.Draft.SupportedFanModes);
        modes[0] = "changed"; Assert.Equal("fullfan", model.Draft.SupportedFanModes![0]);
    }
    [Theory]
    [InlineData("no", 15, "highfan,lowfan")]
    [InlineData("single", 15, "fullfan,quietfan")]
    [InlineData("yes", 15, "fullfan,coolfan,quietfan,quietstopfan")]
    [InlineData("yes", 1, "coolfan")]
    [InlineData("yes", 0, "")]
    public async Task FanChoicesUseDeviceSupport(string kind, int mask, string expected)
    {
        using var f = new Fixture(); var fan = f.Data["SYNO.Core.Hardware.FanSpeed"];
        fan["cool_fan"] = kind; fan["fan_type"] = mask;
        var value = await f.Repository.LoadHardwareSettingsAsync();
        Assert.Equal(expected, string.Join(',', value.SupportedFanModes!));
        Assert.True(NasHardwareSettingsRules.IsValidChange(value, value));
        Assert.False(NasHardwareSettingsRules.IsValidChange(value, value with { FanMode = "highfan" }) && !expected.Split(',').Contains("highfan"));
        Assert.False(NasHardwareSettingsRules.IsValidChange(value, value with { SupportedFanModes = ["guessed"] }));
    }
    [Fact]
    public async Task MissingSupportRetainsRecordedLegacyChoices()
    {
        using var f = new Fixture(); var value = await f.Repository.LoadHardwareSettingsAsync();
        Assert.Null(value.SupportedFanModes); Assert.Equal(NasHardwareSettingsRules.FanModes, NasHardwareSettingsRules.FanChoices(value));
        Assert.True(NasHardwareSettingsRules.IsValidChange(value, value with { FanMode = "highfan" }));
    }
    [Fact]
    public async Task UnsupportedSoundsAreHiddenAndCannotBeIntroduced()
    {
        using var f = new Fixture(); var beep = f.Data["SYNO.Core.Hardware.BeepControl"];
        beep["support_fan_fail"] = false; beep["support_poweron_beep"] = false;
        var value = await f.Repository.LoadHardwareSettingsAsync();
        Assert.Null(value.Beep!.FanFailure); Assert.Null(value.Beep.PowerOn); Assert.True(value.Beep.VolumeFailure);
        Assert.DoesNotContain("fan_fail", NasHardwareSettingsRules.Fields(value, NasHardwareSections.Beep).Keys);
        Assert.False(NasHardwareSettingsRules.IsValidChange(value, value with { Beep = value.Beep with { PowerOn = true } }));
        foreach (var key in new[] { "support_volume_crash", "support_poweroff_beep", "support_reset_beep" }) beep[key] = false;
        var empty = await f.Repository.LoadHardwareSettingsAsync();
        Assert.Empty(NasHardwareSettingsRules.Fields(empty, NasHardwareSections.Beep));
        Assert.False(empty.FailedSections.HasFlag(NasHardwareSections.Beep));
    }
    [Fact]
    public async Task SupportChangeBeforeSaveRejectsWithZeroWrites()
    {
        using var f = new Fixture(); var fan = f.Data["SYNO.Core.Hardware.FanSpeed"];
        fan["cool_fan"] = "yes"; fan["fan_type"] = 15;
        var value = await f.Repository.LoadHardwareSettingsAsync();
        fan["fan_type"] = 1;
        var result = await f.Repository.ExecuteHardwareSettingsWriteAsync(new(f.Profile.Id, value, value with { FanMode = "quietfan" }, Guid.NewGuid(), true));
        Assert.Equal(MutationErrorCategory.Conflict, result.ErrorCategory); Assert.Empty(f.Writes);
    }
}
