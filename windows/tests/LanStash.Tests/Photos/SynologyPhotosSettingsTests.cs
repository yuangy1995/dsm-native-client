using System.Text;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;
using MemoryStore = LanStash.Tests.SynologyPhotosUploadTests.MemoryStore;

namespace LanStash.Tests;

public sealed class SynologyPhotosSettingsTests
{
    [Theory]
    [InlineData(false, true)] [InlineData(true, false)] [InlineData(false, false)] [InlineData(true, true)]
    public async Task OnlyChangedBooleanIsWrittenAndReadBack(bool original, bool desired)
    {
        using var f = new Fixture { Enabled = original }; var repo = await f.Repository(); var id = Guid.NewGuid();
        var result = await repo.SetAutomaticPreviewAsync(id, original, desired);
        Assert.Equal(SynologyPhotoChangeState.Completed, result.State); Assert.Equal(desired, f.Enabled); Assert.Equal(original == desired ? 0 : 1, f.Writes);
        await repo.SetAutomaticPreviewAsync(id, original, desired); Assert.Equal(original == desired ? 0 : 1, f.Writes);
        var saved = Encoding.UTF8.GetString(f.Store.Records[id]); Assert.DoesNotContain("synthetic-sid", saved); Assert.DoesNotContain("nas.invalid", saved);
        Assert.DoesNotContain("synthetic-user", saved); Assert.DoesNotContain("synthetic-token", saved);
    }
    [Theory]
    [InlineData(false)] [InlineData(true)]
    public async Task LostReplyRestartsReadonlyWithoutAnotherWrite(bool applied)
    {
        using var f = new Fixture { Apply = false, Status = SynologyPhotoWriteStatus.Unknown }; var repo = await f.Repository(); var id = Guid.NewGuid();
        Assert.True((await repo.SetAutomaticPreviewAsync(id, false, true)).Pending);
        var cold = await f.Repository(f.Store.Clone()); f.Enabled = applied;
        var result = await cold.SetAutomaticPreviewAsync(id, false, true);
        Assert.Equal(applied ? SynologyPhotoChangeState.Completed : SynologyPhotoChangeState.PendingReview, result.State); Assert.Equal(1, f.Writes);
        if (!applied)
        {
            Assert.Equal(SynologyPhotoFailure.UploadBusy, (await Assert.ThrowsAsync<SynologyPhotoException>(() => cold.SetAutomaticPreviewAsync(Guid.NewGuid(), false, true))).Failure);
            Assert.Equal(SynologyPhotoFailure.TargetChanged, (await Assert.ThrowsAsync<SynologyPhotoException>(() => cold.SetAutomaticPreviewAsync(id, true, false))).Failure);
        }
        Assert.Equal(1, f.Writes);
    }
    [Theory]
    [InlineData("stale")] [InlineData("missing")] [InlineData("permission")] [InlineData("owner")]
    public async Task StaleOriginalMissingFieldAndRevokedAccessNeverWrite(string problem)
    {
        using var f = new Fixture(); var repo = await f.Repository();
        if (problem == "stale") f.Enabled = true; if (problem == "missing") f.Missing = true;
        if (problem == "permission") f.Http.Enabled = false; if (problem == "owner") f.Http.UserId++;
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.SetAutomaticPreviewAsync(Guid.NewGuid(), false, true)); Assert.Equal(0, f.Writes);
    }
    [Theory]
    [InlineData("change")] [InlineData("cancel")] [InlineData("generation")]
    public async Task RechecksAfterCheckpointBeforeTransport(string problem)
    {
        using var f = new Fixture(); using var cancel = new CancellationTokenSource(); var repo = await f.Repository();
        f.Store.AfterSave = async raw =>
        {
            if (raw["Settings"]?["State"]?.GetValue<int>() != (int)SynologyPhotoChangeState.Submitting) return;
            if (problem == "change") f.Enabled = true; if (problem == "cancel") cancel.Cancel(); if (problem == "generation") await repo.AccessAsync();
        };
        var result = await repo.SetAutomaticPreviewAsync(Guid.NewGuid(), false, true, cancel.Token);
        Assert.Equal(0, f.Writes); Assert.False(result.Pending); Assert.NotEqual(SynologyPhotoChangeState.Completed, result.State);
    }
    [Theory]
    [InlineData(1)] [InlineData(2)]
    public async Task FailedCheckpointClosesWrites(int save)
    {
        using var f = new Fixture(); var saves = 0; f.Store.FailSave = _ => ++saves == save; var repo = await f.Repository();
        Assert.Equal(SynologyPhotoFailure.RecoveryUnavailable, (await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.SetAutomaticPreviewAsync(Guid.NewGuid(), false, true))).Failure);
        Assert.Equal(0, f.Writes);
    }
    [Theory]
    [InlineData(SynologyPhotoWriteStatus.Accepted)] [InlineData(SynologyPhotoWriteStatus.Rejected)] [InlineData(SynologyPhotoWriteStatus.Unknown)]
    public async Task LateCancellationPreservesReceiptAndNeverReplays(SynologyPhotoWriteStatus status)
    {
        using var f = new Fixture { Status = status, Apply = false }; using var cancel = new CancellationTokenSource(); var repo = await f.Repository(); f.OnWrite = cancel.Cancel;
        var result = await repo.SetAutomaticPreviewAsync(Guid.NewGuid(), false, true, cancel.Token);
        Assert.Equal(status == SynologyPhotoWriteStatus.Rejected ? SynologyPhotoChangeState.Failed : SynologyPhotoChangeState.PendingReview, result.State);
        var cold = await f.Repository(f.Store.Clone()); await cold.ReviewSettingsChangeAsync(result.Id); Assert.Equal(1, f.Writes);
    }
    [Fact]
    public async Task ConcurrentSameOperationIsSubmittedOnce()
    {
        using var f = new Fixture(); var repo = await f.Repository(); var entered = new TaskCompletionSource(); var release = new TaskCompletionSource();
        f.WaitWrite = async () => { entered.SetResult(); await release.Task; }; var id = Guid.NewGuid();
        var first = repo.SetAutomaticPreviewAsync(id, false, true); await entered.Task;
        Assert.True((await repo.SetAutomaticPreviewAsync(id, false, true)).Pending); release.SetResult(); await first; Assert.Equal(1, f.Writes);
    }
    [Fact]
    public async Task OtherOwnerCannotReadOrReviewTheSetting()
    {
        using var f = new Fixture { Apply = false }; var repo = await f.Repository(); var first = await repo.SetAutomaticPreviewAsync(Guid.NewGuid(), false, true);
        var profile = f.Http.Profile with { Username = "synthetic-other" };
        var other = new SynologyPhotosRepository(profile, f.Http.Session, f, f.Http.Capabilities, managementStore: f.Store);
        await other.AccessAsync(); Assert.Empty(await other.SettingsChangesAsync());
        Assert.Equal(SynologyPhotoFailure.Permission, (await Assert.ThrowsAsync<SynologyPhotoException>(() => other.ReviewSettingsChangeAsync(first.Id))).Failure); Assert.Equal(1, f.Writes);
    }
    [Fact]
    public async Task CrashAtCheckpointDoesNotReexecute()
    {
        using var f = new Fixture { Apply = false }; var repo = await f.Repository(); var result = await repo.SetAutomaticPreviewAsync(Guid.NewGuid(), false, true);
        var store = f.Store.Clone(); var raw = JsonNode.Parse(store.Records[result.Id])!; raw["Settings"]!["State"] = (int)SynologyPhotoChangeState.Submitting;
        store.Records[result.Id] = Encoding.UTF8.GetBytes(raw.ToJsonString()); var cold = await f.Repository(store);
        Assert.True((await cold.SetAutomaticPreviewAsync(result.Id, false, true)).Pending); Assert.Equal(1, f.Writes);
    }
    private sealed class Fixture : IDsmApiClient, IDisposable
    {
        internal readonly SynologyPhotosHttpFixture Http = new(); internal readonly MemoryStore Store = new();
        internal bool Enabled, Missing, Apply = true; internal int Writes;
        internal SynologyPhotoWriteStatus Status = SynologyPhotoWriteStatus.Accepted;
        internal Action? OnWrite; internal Func<Task>? WaitWrite;
        internal Fixture() => Http.AccessResponse = api => api == "SYNO.Foto.Setting.User" ? User() : null;
        private JsonObject User()
        {
            var value = new JsonObject { ["enable_home_service"] = true, ["team_space_permission"] = "none" };
            if (!Missing) value["auto_generate_thumbnail"] = Enabled; return value;
        }
        internal async Task<SynologyPhotosRepository> Repository(MemoryStore? store = null)
        { var repo = new SynologyPhotosRepository(Http.Profile, Http.Session, this, Http.Capabilities, managementStore: store ?? Store); await repo.AccessAsync(); return repo; }
        public async Task<SynologyPhotoWriteReceipt> WritePhotoAsync(NasProfile profile, DsmSession session, ApiCapability capability, int requiredVersion,
            string method, IReadOnlyDictionary<string, string> parameters, CancellationToken cancellationToken = default)
        {
            Assert.Equal("SYNO.Foto.Setting.User", capability.Name); Assert.Equal(1, requiredVersion); Assert.Equal("set", method);
            Assert.Equal("auto_generate_thumbnail", Assert.Single(parameters).Key); Writes++; OnWrite?.Invoke(); if (WaitWrite is not null) await WaitWrite();
            if (Apply && Status != SynologyPhotoWriteStatus.Rejected) Enabled = parameters["auto_generate_thumbnail"] == "true";
            return new(Status, Failure: Status == SynologyPhotoWriteStatus.Rejected ? SynologyPhotoFailure.Permission : null);
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
