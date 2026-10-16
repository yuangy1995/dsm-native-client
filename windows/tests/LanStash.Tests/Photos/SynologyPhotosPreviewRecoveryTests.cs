using System.Text;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Tests;

public sealed partial class SynologyPhotosPreviewGenerationTests
{
    [Theory]
    [InlineData("profile")]
    [InlineData("media")]
    [InlineData("album")]
    [InlineData("baseline-type")]
    [InlineData("unmarked-submit")]
    [InlineData("unsubmitted-reject")]
    [InlineData("unsubmitted-generated")]
    [InlineData("unrestored")]
    [InlineData("false-complete")]
    public async Task InvalidColdRecordClosesRecoveryWithoutWriting(string corruption)
    {
        using var f = new Fixture { Problem = "nas-lost" }; var repo = await f.Repository(); var result = await repo.GeneratePreviewsAsync(Guid.NewGuid(), f.Request());
        var store = f.Store.Clone(); var root = JsonNode.Parse(store.Records[result.Id])!; var item = root["Preview"]!["Items"]![0]!;
        switch (corruption)
        {
            case "profile": item["Original"]!["Id"]!["ProfileId"] = Guid.NewGuid().ToString(); break;
            case "media": item["Original"]!["MediaType"] = "unsupported"; break;
            case "album": item["Original"]!["AlbumContext"] = new JsonObject { ["AlbumId"] = 0, ["OwnerUserId"] = 19, ["ProviderUserId"] = 19 }; break;
            case "baseline-type": item["Baseline"]!["Type"] = 2; break;
            case "unmarked-submit": item["Marked"] = false; break;
            case "unsubmitted-reject": item["LocalRejected"] = true; break;
            case "unsubmitted-generated": item["NasSubmitted"] = false; item["Generated"] = true; break;
            case "unrestored": item["Restored"] = true; break;
            default: item["State"] = (int)SynologyPhotoChangeState.Completed; break;
        }
        store.Records[result.Id] = Encoding.UTF8.GetBytes(root.ToJsonString()); var cold = await f.Repository(store); var writes = f.Writes;
        Assert.Equal(SynologyPhotoFailure.RecoveryUnavailable, (await Assert.ThrowsAsync<SynologyPhotoException>(() => cold.PreviewGenerationsAsync())).Failure); Assert.Equal(writes, f.Writes);
    }
    [Theory]
    [InlineData("photo", ".gif")]
    [InlineData("photo", ".webp")]
    [InlineData("unsupported", ".jpg")]
    public async Task UnsupportedMediaCannotCreateTask(string media, string extension)
    {
        using var f = new Fixture { Extension = extension }; var repo = await f.Repository();
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.GeneratePreviewsAsync(Guid.NewGuid(), new([f.Photo() with { MediaType = media }])));
        Assert.Empty(f.Store.Records); Assert.Empty(f.Events);
    }
    [Fact]
    public async Task PartialBatchPreservesCompletionAndDoesNotStartLaterItems()
    {
        using var f = new Fixture(); var repo = await f.Repository();
        f.BeforeRead = call => { if (call.Method == "set_regenerating" && call.Values["item_id"] == "[8]") f.Problem = "nas-lost"; };
        var result = await repo.GeneratePreviewsAsync(Guid.NewGuid(), new([f.Photo(), f.Photo(8), f.Photo(9)]));
        Assert.Equal([SynologyPhotoChangeState.Completed, SynologyPhotoChangeState.PendingReview, SynologyPhotoChangeState.Ready], result.Items.Select(item => item.State)); Assert.Equal(4, f.Writes);
        var cold = await f.Repository(f.Store.Clone()); result = await cold.ContinuePreviewGenerationAsync(result.Id); Assert.Equal(4, f.Writes);
        Assert.Equal(SynologyPhotoChangeState.Completed, result.Items[0].State); Assert.Equal(SynologyPhotoChangeState.Ready, result.Items[2].State);
    }
    [Fact]
    public async Task UnknownMarkWithoutQueueEvidenceRemainsUnknown()
    {
        using var f = new Fixture { Problem = "mark-lost" }; var repo = await f.Repository(); var result = await repo.GeneratePreviewsAsync(Guid.NewGuid(), f.Request()); f.Queued.Clear(); f.Revision = "new-preview";
        var cold = await f.Repository(f.Store.Clone()); result = await cold.ReviewPreviewGenerationAsync(result.Id); Assert.True(result.Pending); Assert.False(result.CanContinue); Assert.Equal(1, f.Writes);
    }
    [Fact]
    public async Task SameOperationIdCannotChangeSelectionOrResumeIntent()
    {
        using var f = new Fixture { Problem = "nas-lost" }; var repo = await f.Repository(); var id = Guid.NewGuid(); await repo.GeneratePreviewsAsync(id, f.Request());
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.GeneratePreviewsAsync(id, f.Request(resuming: true)));
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.GeneratePreviewsAsync(id, new([f.Photo(8)]))); Assert.Equal(2, f.Writes);
    }
    [Fact]
    public async Task PermissionRevokedAfterMarkDoesNotSubmitNasConversion()
    {
        using var f = new Fixture(); var repo = await f.Repository();
        f.Store.AfterSave = record => { if (record["Preview"]?["Items"]?[0]?["Marked"]?.GetValue<bool>() == true) f.Manage = false; return Task.CompletedTask; };
        var result = await repo.GeneratePreviewsAsync(Guid.NewGuid(), f.Request()); Assert.False(result.Completed); Assert.Equal(1, f.Writes); Assert.DoesNotContain("regenerate_preview_by_nas", f.Events);
    }
    [Fact]
    public async Task PendingPreviewPreservesAlbumContextAgainstConcurrentAlbumMutation()
    {
        using var f = new Fixture { Album = new(41, 19, 19), Problem = "nas-lost" };
        f.Http.Capabilities["SYNO.Foto.Browse.NormalAlbum"] = new("SYNO.Foto.Browse.NormalAlbum", "entry.cgi", 1, 1, "JSON");
        var repo = await f.Repository(); await repo.GeneratePreviewsAsync(Guid.NewGuid(), f.Request());
        var edit = new SynologyPhotoAlbumEdit(SynologyPhotoAlbumEditKind.Rename) { Album = new(41, 19, 19, "Synthetic", false, false, new string('A', 64)) { ProfileId = f.Http.ProfileId }, Name = "Renamed" };
        Assert.Equal(SynologyPhotoFailure.UploadBusy, (await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.PrepareAlbumAsync(edit))).Failure); Assert.Equal(2, f.Writes);
    }
}
