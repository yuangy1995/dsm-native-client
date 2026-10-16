using System.Text;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;
using LanStash.App.Features.Photos.Synology;
using MemoryStore = LanStash.Tests.SynologyPhotosUploadTests.MemoryStore;

namespace LanStash.Tests;

public sealed class SynologyPhotosPreferencesTests
{
    [Fact]
    public async Task DisplayWritesOnlyChangedFieldsAndAppliesStrictReadback()
    {
        using var f = new Fixture(); var repo = await f.Repository(); var original = await repo.DisplaySettingsAsync();
        var updated = original with { Grouping = SynologyPhotoGrouping.Month, DateFormat = SynologyPhotoDateFormat.DayDot, TwelveHourClock = true,
            DefaultSort = new(SynologyPhotoSortField.Filename, true), ShowsPreviewInfo = true };
        var result = await repo.SetDisplaySettingsAsync(Guid.NewGuid(), original, updated);
        Assert.Equal(SynologyPhotoChangeState.Completed, result.State); Assert.Equal(updated, result.Display!.Updated);
        var write = Assert.Single(f.Writes); Assert.Equal(6, write.Count); Assert.Equal("\"month\"", write["timeline_group_unit"]);
        Assert.Equal("\"dd.mm.yyyy\"", write["date_format"]); Assert.Equal("\"12\"", write["time_format"]); Assert.Equal("\"filename\"", write["item_sort_by"]);
        Assert.Equal("\"desc\"", write["sort_direction"]); Assert.Equal("true", write["show_item_info_in_lightbox"]);
        var cold = await f.Repository(f.Store.Clone()); var repeated = await cold.SetDisplaySettingsAsync(result.Id, original, updated);
        Assert.Equal(SynologyPhotoChangeState.Completed, repeated.State); Assert.Single(f.Writes);
    }
    [Theory]
    [InlineData("timeline_group_unit")] [InlineData("date_format")] [InlineData("time_format")]
    [InlineData("item_sort_by")] [InlineData("sort_direction")] [InlineData("show_item_info_in_lightbox")]
    public async Task InvalidDisplayFieldDoesNotBlockAccessButCannotBeSaved(string field)
    {
        using var f = new Fixture(); f.User[field] = 17; var repo = await f.Repository();
        Assert.Null((await repo.AccessAsync()).DisplaySettings); await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.DisplaySettingsAsync()); Assert.Empty(f.Writes);
    }
    [Theory]
    [InlineData("display")] [InlineData("duplicates")] [InlineData("recognition")]
    public async Task UnchangedPreferencesHaveNoWrites(string kind)
    {
        using var f = new Fixture(); var repo = await f.Repository(); var change = await f.Change(repo, kind, change: false);
        Assert.Equal(SynologyPhotoChangeState.Completed, change.State); Assert.Empty(f.Writes);
        var cold = await f.Repository(f.Store.Clone()); Assert.Equal(change.State, (await cold.ReviewSettingsChangeAsync(change.Id)).State);
    }
    [Theory]
    [InlineData("display", false)] [InlineData("display", true)] [InlineData("duplicates", false)] [InlineData("duplicates", true)]
    [InlineData("recognition", false)] [InlineData("recognition", true)]
    public async Task UnknownWriteSurvivesRestartAndOnlyReads(string kind, bool applied)
    {
        using var f = new Fixture { Apply = false, Status = SynologyPhotoWriteStatus.Unknown }; var repo = await f.Repository();
        var change = await f.Change(repo, kind); Assert.True(change.Pending); var store = f.Store.Clone();
        if (applied) f.ApplyWrite(Assert.Single(f.Writes));
        var cold = await f.Repository(store); var result = await cold.ReviewSettingsChangeAsync(change.Id);
        Assert.Equal(applied ? SynologyPhotoChangeState.Completed : SynologyPhotoChangeState.PendingReview, result.State); Assert.Single(f.Writes);
        if (!applied) Assert.Equal(SynologyPhotoFailure.UploadBusy, (await Assert.ThrowsAsync<SynologyPhotoException>(() => cold.SetAutomaticPreviewAsync(Guid.NewGuid(), false, true))).Failure);
        Assert.Single(f.Writes);
    }
    [Theory]
    [InlineData("display")] [InlineData("duplicates")] [InlineData("recognition")]
    public async Task ChangingOriginalAtCheckpointStopsTransport(string kind)
    {
        using var f = new Fixture(); var repo = await f.Repository(); f.Store.AfterSave = raw =>
        {
            if (raw["Settings"]?["Submitted"]?.GetValue<bool>() == true)
            { f.User["show_item_info_in_lightbox"] = true; f.User["upload_default_action"] = "rename"; f.Admin["enable_person"] = false; }
            return Task.CompletedTask;
        };
        var result = await f.Change(repo, kind); Assert.Equal(SynologyPhotoChangeState.Failed, result.State); Assert.Empty(f.Writes);
    }
    [Theory]
    [InlineData("display")] [InlineData("duplicates")] [InlineData("recognition")]
    public async Task ExplicitRejectionIsTerminalEvenWhenAnotherClientMatches(string kind)
    {
        using var f = new Fixture { Apply = false, Status = SynologyPhotoWriteStatus.Rejected }; var repo = await f.Repository(); var change = await f.Change(repo, kind);
        f.ApplyWrite(Assert.Single(f.Writes)); var result = await (await f.Repository(f.Store.Clone())).ReviewSettingsChangeAsync(change.Id);
        Assert.Equal(SynologyPhotoChangeState.Failed, result.State); Assert.Single(f.Writes);
    }
    [Theory]
    [InlineData("home")] [InlineData("global")] [InlineData("unknown")] [InlineData("invented")]
    public async Task RecognitionCannotChangeNonEditableOrPermissionFields(string reason)
    {
        using var f = new Fixture(); if (reason == "home") f.User["enable_home_service"] = false;
        if (reason == "global") f.Admin["enable_person"] = false; if (reason == "unknown") f.Admin.Remove("enable_person");
        var repo = await f.Repository(); var original = await repo.RecognitionSettingsAsync();
        var updated = reason == "invented" ? original with { GlobalPeople = false } : original with { People = !(original.People ?? false) };
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.SetRecognitionSettingsAsync(Guid.NewGuid(), original, updated)); Assert.Empty(f.Writes);
    }
    [Fact]
    public async Task RecognitionOnlyWritesPersonalDeltaAndKeepsGlobalConditions()
    {
        using var f = new Fixture(); var repo = await f.Repository(); var original = await repo.RecognitionSettingsAsync();
        var result = await repo.SetRecognitionSettingsAsync(Guid.NewGuid(), original, original with { People = false });
        Assert.Equal(SynologyPhotoChangeState.Completed, result.State); Assert.Equal(new KeyValuePair<string,string>("enable_person", "false"), Assert.Single(Assert.Single(f.Writes)));
        Assert.True(f.Admin["enable_person"]!.GetValue<bool>());
    }
    [Fact]
    public async Task DuplicatePreferenceWorksWhenPersonalLibraryIsClosed()
    {
        using var f = new Fixture(); f.User["enable_home_service"] = false; var repo = await f.Repository();
        var original = await repo.DuplicateSettingsAsync(); var result = await repo.SetDuplicateSettingsAsync(Guid.NewGuid(), original, original with { Upload = SynologyPhotoDuplicatePolicy.KeepBoth });
        Assert.Equal(SynologyPhotoChangeState.Completed, result.State); Assert.Equal(new KeyValuePair<string,string>("upload_default_action", "\"rename\""), Assert.Single(Assert.Single(f.Writes)));
    }
    [Theory]
    [InlineData("upload_default_action")] [InlineData("copy_move_default_action")]
    public async Task UnknownDuplicatePreferenceNeverGuesses(string field)
    {
        using var f = new Fixture(); f.User[field] = "future"; var repo = await f.Repository(); await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.DuplicateSettingsAsync()); Assert.Empty(f.Writes);
    }
    [Fact]
    public async Task CorruptMultipleSettingPayloadsCloseRecoveryWrites()
    {
        using var f = new Fixture { Apply = false }; var repo = await f.Repository(); var result = await f.Change(repo, "display");
        var store = f.Store.Clone(); var raw = JsonNode.Parse(store.Records[result.Id])!; raw["Settings"]!["Automatic"] = new JsonObject { ["Original"] = false, ["Enabled"] = true };
        store.Records[result.Id] = Encoding.UTF8.GetBytes(raw.ToJsonString()); var cold = await f.Repository(store);
        Assert.Equal(SynologyPhotoFailure.RecoveryUnavailable, (await Assert.ThrowsAsync<SynologyPhotoException>(() => cold.SettingsChangesAsync())).Failure); Assert.Single(f.Writes);
    }
    [Theory]
    [InlineData(SynologyPhotoDateFormat.YearDash, "2026-10-25", "2026-10")]
    [InlineData(SynologyPhotoDateFormat.DaySlash, "25/10/2026", "10/2026")]
    [InlineData(SynologyPhotoDateFormat.MonthDot, "10.25.2026", "10.2026")]
    public void DisplayDateUsesSelectedFormatAndCalendarYear(SynologyPhotoDateFormat format, string date, string month)
    {
        var settings = new SynologyPhotoDisplaySettings(SynologyPhotoGrouping.Day, format, true, new(), true); var instant = new DateTime(2026, 10, 25, 15, 7, 0);
        var culture = System.Globalization.CultureInfo.GetCultureInfo("en-US");
        Assert.Equal(date, SynologyPhotosWorkspace.FormatDisplayDate(instant, settings, false, false, culture));
        Assert.Equal(month, SynologyPhotosWorkspace.FormatDisplayDate(instant, settings, false, true, culture));
        Assert.EndsWith("3:07 PM", SynologyPhotosWorkspace.FormatDisplayDate(instant, settings, true, false, culture));
    }
    private sealed class Fixture : IDsmApiClient, IDisposable
    {
        internal readonly SynologyPhotosHttpFixture Http = new(); internal readonly MemoryStore Store = new();
        internal readonly List<IReadOnlyDictionary<string, string>> Writes = [];
        internal bool Apply = true; internal SynologyPhotoWriteStatus Status = SynologyPhotoWriteStatus.Accepted;
        internal readonly JsonObject User = new() { ["enable_home_service"] = true, ["team_space_permission"] = "none", ["auto_generate_thumbnail"] = false,
            ["timeline_group_unit"] = "day", ["date_format"] = "YYYY-MM-DD", ["time_format"] = "24", ["item_sort_by"] = "takentime", ["sort_direction"] = "asc",
            ["show_item_info_in_lightbox"] = false, ["upload_default_action"] = "ignore", ["copy_move_default_action"] = "skip",
            ["enable_person"] = true, ["enable_concept"] = false, ["enable_similar"] = true };
        internal readonly JsonObject Admin = new() { ["package_version"] = "synthetic", ["enable_person"] = true, ["enable_concept"] = true, ["enable_similar"] = true };
        internal Fixture() => Http.AccessResponse = api => api switch { "SYNO.Foto.Setting.User" => (JsonObject)User.DeepClone(), "SYNO.Foto.Setting.Admin" => (JsonObject)Admin.DeepClone(), _ => null };
        internal async Task<SynologyPhotosRepository> Repository(MemoryStore? store = null)
        { var repo = new SynologyPhotosRepository(Http.Profile, Http.Session, this, Http.Capabilities, managementStore: store ?? Store); await repo.AccessAsync(); return repo; }
        internal async Task<SynologyPhotoSettingsChange> Change(SynologyPhotosRepository repo, string kind, bool change = true)
        {
            if (kind == "display") { var a = await repo.DisplaySettingsAsync(); return await repo.SetDisplaySettingsAsync(Guid.NewGuid(), a, change ? a with { ShowsPreviewInfo = true } : a); }
            if (kind == "duplicates") { var a = await repo.DuplicateSettingsAsync(); return await repo.SetDuplicateSettingsAsync(Guid.NewGuid(), a, change ? a with { Upload = SynologyPhotoDuplicatePolicy.KeepBoth } : a); }
            var r = await repo.RecognitionSettingsAsync(); return await repo.SetRecognitionSettingsAsync(Guid.NewGuid(), r, change ? r with { People = false } : r);
        }
        internal void ApplyWrite(IReadOnlyDictionary<string, string> values) { foreach (var (key, value) in values) User[key] = JsonNode.Parse(value); }
        public Task<SynologyPhotoWriteReceipt> WritePhotoAsync(NasProfile profile, DsmSession session, ApiCapability capability, int requiredVersion,
            string method, IReadOnlyDictionary<string, string> parameters, CancellationToken cancellationToken = default)
        {
            Assert.Equal("SYNO.Foto.Setting.User", capability.Name); Assert.Equal(1, requiredVersion); Assert.Equal("set", method); Writes.Add(new Dictionary<string, string>(parameters));
            if (Apply && Status != SynologyPhotoWriteStatus.Rejected) ApplyWrite(parameters); return Task.FromResult(new SynologyPhotoWriteReceipt(Status));
        }
        public Task<JsonObject> CallPhotoJsonAsync(NasProfile profile, DsmSession session, ApiCapability capability, int requiredVersion, string method, IReadOnlyDictionary<string, string>? parameters = null, CancellationToken cancellationToken = default) => Http.Api.CallPhotoJsonAsync(profile, session, capability, requiredVersion, method, parameters, cancellationToken);
        public Uri GetBaseUri(NasProfile profile) => Http.Api.GetBaseUri(profile);
        public Task<IReadOnlyDictionary<string, ApiCapability>> DiscoverAsync(NasProfile profile, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<DsmSession> LoginAsync(NasProfile profile, string password, string? otp, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task LogoutAsync(NasProfile profile, DsmSession session, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<JsonObject> CallAsync(NasProfile profile, DsmSession session, ApiCapability capability, string method, IReadOnlyDictionary<string, string>? parameters = null, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<byte[]> ReadFileRangeAsync(NasProfile profile, DsmSession session, ApiCapability capability, string remotePath, long offset, long length, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public void Dispose() => Http.Dispose();
    }
}
