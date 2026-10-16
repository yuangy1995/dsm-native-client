using System.Net;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests;

public sealed class SynologyPhotosAutomaticCandidateTests
{
    [Theory]
    [InlineData(true, true, "windows")][InlineData(false, true, "windows2")][InlineData(true, false, "macos")][InlineData(false, false, "macos")]
    public async Task BackgroundCandidatesUseRecordedTypePresetAndUnitIdentity(bool hevc, bool vc1, string preset)
    {
        using var f = new Fixture(); var repo = await f.Repository(); var items = await repo.AutomaticPreviewCandidatesAsync(f.Space, new(hevc, vc1, true));
        var item = Assert.Single(items); Assert.Equal(81, item.UnitId); Assert.Null(item.SourcePhoto); Assert.Equal(8, item.TypeCode);
        Assert.True(item.NeedsThumbnail); Assert.True(item.NeedsVideo); Assert.Equal(SynologyPhotoAutomaticPriority.Background, item.Priority);
        var request = Assert.Single(f.Http.Requests, r => r.Method == "list_convert_needed"); Assert.Equal(3, request.Version);
        Assert.Equal(JsonSerializer.Serialize(preset), request.Values["preset"]);
        Assert.Equal(hevc ? "[\"photo\",\"video\",\"live_video\"]" : "[\"video\"]", request.Values["type"]);
        Assert.DoesNotContain("offset", request.Values.Keys); Assert.DoesNotContain("limit", request.Values.Keys);
    }
    [Theory]
    [InlineData("missing")][InlineData("string")][InlineData("number")][InlineData("negative")][InlineData("duplicate")][InlineData("zero")][InlineData("empty")][InlineData("photo-video")]
    public async Task MalformedCandidateBatchIsRejectedWhole(string problem)
    {
        using var f = new Fixture { Problem = problem }; var repo = await f.Repository();
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.AutomaticPreviewCandidatesAsync(f.Space, new(true, true, true)));
        Assert.All(f.Http.Requests, r => Assert.Contains(r.Method, new[] { "me", "get", "list_convert_needed" }));
    }
    [Fact]
    public async Task MissingSystemCodecsDoNotScanOrReadMedia()
    {
        using var f = new Fixture(); var repo = await f.Repository(); Assert.Empty(await repo.AutomaticPreviewCandidatesAsync(f.Space, new(false, false, false)));
        Assert.Empty(await repo.AutomaticPreviewCandidatesAsync(f.Photo, new(false, false, false)));
        Assert.DoesNotContain(f.Http.Requests, r => r.Method == "list_convert_needed" || r.Api.EndsWith("Browse.Item"));
    }
    [Theory]
    [InlineData("entry", true, true, false)][InlineData("entry", false, true, false)][InlineData("entry", true, false, false)][InlineData("management", false, false, true)]
    public async Task SharedVisiblePermissionIsIndependentFromWholeLibraryScan(string role, bool view, bool download, bool background)
    {
        using var f = new Fixture(SynologyPhotoSpace.Shared) { View = view, Download = download }; f.Http.TeamPermission = role; var repo = await f.Repository();
        if (background) Assert.Single(await repo.AutomaticPreviewCandidatesAsync(f.Space, new(true, true, true)));
        else await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.AutomaticPreviewCandidatesAsync(f.Space, new(true, true, true)));
        if (background || view && download) Assert.Single(await repo.AutomaticPreviewCandidatesAsync(f.Photo, new(true, true, true)));
        else Assert.Equal(SynologyPhotoFailure.Permission, (await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.AutomaticPreviewCandidatesAsync(f.Photo, new(true, true, true)))).Failure);
    }
    [Theory]
    [InlineData("id")][InlineData("filename")][InlineData("filesize")][InlineData("folder_id")][InlineData("indexed_time")][InlineData("type")][InlineData("owner_user_id")][InlineData("unit")]
    public async Task VisibleCandidateMustMatchCurrentPhysicalIdentityAndOwner(string changed)
    {
        using var f = new Fixture { Changed = changed }; var repo = await f.Repository();
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.AutomaticPreviewCandidatesAsync(f.Photo, new(true, true, true)));
    }
    [Theory]
    [InlineData("heic", "photo", "", false, true, false, 0)]
    [InlineData("jpg", "photo", "", false, true, false, 1)]
    [InlineData("mp4", "video", "hevc", false, true, false, 0)]
    [InlineData("mp4", "video", "hevc", true, true, false, 2)]
    [InlineData("wmv", "video", "wmv3", false, true, false, 0)]
    [InlineData("wmv", "video", "wmv3", false, true, true, 3)]
    [InlineData("mp4", "video", "h264", false, true, false, 1)]
    [InlineData("mp4", "video", "h264", true, false, false, 0)]
    public async Task VisibleDefectsFollowActualCodecSupportAndPriority(string extension, string media, string codec, bool hevc, bool video, bool vc1, int priority)
    {
        using var f = new Fixture { Extension = extension, Media = media, Codec = codec }; var repo = await f.Repository();
        var candidates = await repo.AutomaticPreviewCandidatesAsync(f.Photo, new(hevc, vc1, video));
        if (priority == 0) Assert.Empty(candidates); else Assert.Equal(priority, (int)Assert.Single(candidates).Priority);
        var request = Assert.Single(f.Http.Requests, r => r.Api.EndsWith("Browse.Item"));
        Assert.Equal("[7]", request.Values["id"]); Assert.Contains("\"video_convert\"", request.Values["additional"]); Assert.DoesNotContain("video_convert_status", request.Values["additional"]);
    }
    [Fact]
    public async Task LiveUnitsUseOwnIdentityAndBothDefectsWithoutItemIdSubstitution()
    {
        using var f = new Fixture { Media = "live" }; var repo = await f.Repository(); var result = await repo.AutomaticPreviewCandidatesAsync(f.Photo, new(true, true, true));
        Assert.Equal(new long[] { 81, 82 }, result.Select(t => t.UnitId)); Assert.Equal(new[] { 0, 1 }, result.Select(t => t.TypeCode));
        Assert.Equal(new[] { SynologyPhotoAutomaticPriority.Standard, SynologyPhotoAutomaticPriority.HevcOrLiveVideo }, result.Select(t => t.Priority));
        Assert.All(result, t => Assert.Equal(f.Photo.Id, t.SourcePhoto!.Id));
        Assert.Equal("[7]", Assert.Single(f.Http.Requests, r => r.Api.EndsWith("Browse.Unit")).Values["id_item"]);
    }
    [Theory]
    [InlineData("live-item")][InlineData("live-duplicate")][InlineData("live-type")][InlineData("live-thumb")][InlineData("live-filename")]
    public async Task InvalidLiveMembershipRejectsAllCandidates(string problem)
    {
        using var f = new Fixture { Media = "live", Problem = problem }; var repo = await f.Repository();
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.AutomaticPreviewCandidatesAsync(f.Photo, new(true, true, true)));
    }
    [Fact]
    public async Task ReadyMediaAndMissingSettingNeverBecomeAutomaticWrites()
    {
        using var f = new Fixture { Defect = false }; var repo = await f.Repository(); Assert.Empty(await repo.AutomaticPreviewCandidatesAsync(f.Photo, new(true, true, true)));
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.AutomaticPreviewEnabledAsync());
        f.Http.AccessResponse = api => api == "SYNO.Foto.Setting.User" ? new JsonObject { ["auto_generate_thumbnail"] = false } : null;
        Assert.False(await repo.AutomaticPreviewEnabledAsync());
    }
    [Fact]
    public async Task ForeignProfileDoesNotReadAnything()
    {
        using var f = new Fixture(); var repo = await f.Repository(); var before = f.Http.Requests.Count;
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.AutomaticPreviewCandidatesAsync(f.Photo with { Id = f.Photo.Id with { ProfileId = Guid.NewGuid() } }, new(true, true, true)));
        Assert.Equal(before, f.Http.Requests.Count);
    }
    private sealed class Fixture : IDisposable
    {
        internal readonly SynologyPhotosHttpFixture Http = new() { TeamEnabled = true, TeamPermission = "management" };
        internal readonly SynologyPhotoSpace Space;
        internal string? Problem, Changed;
        internal string Media = "photo", Extension = "jpg", Codec = "h264";
        internal bool View = true, Download = true, Defect = true;
        internal SynologyPhoto Photo => Http.Photo with { Id = Http.Photo.Id with { Space = Space }, Filename = "synthetic." + Extension, MediaType = Media };
        internal Fixture(SynologyPhotoSpace space = SynologyPhotoSpace.Personal)
        {
            Space = space; Http.Respond = Respond;
            foreach (var name in new[] { "SYNO.Foto.Upload.ConvertedFile", "SYNO.FotoTeam.Upload.ConvertedFile" }) Http.Capabilities[name] = new(name, "entry.cgi", 1, 3, "JSON");
        }
        internal async Task<SynologyPhotosRepository> Repository() { var repo = Http.Repository(); await repo.AccessAsync(); return repo; }
        private JsonObject Extra(long id) => new() { ["thumbnail"] = new JsonObject { ["unit_id"] = id, ["cache_key"] = "r", ["xl"] = Defect ? "ame_defect" : "ready", ["sm"] = "ready" },
            ["video_meta"] = new JsonObject { ["video_codec"] = Codec }, ["video_convert_status"] = Defect ? "ame_defect" : "ready" };
        private Task<HttpResponseMessage> Respond(SynologyPhotosHttpFixture.Request call, CancellationToken token)
        {
            JsonObject data;
            if (call.Method == "list_convert_needed")
            {
                var item = new JsonObject { ["unit_id"] = 81, ["filename"] = "synthetic.mp4", ["type"] = 8, ["need_thumbnail"] = true, ["need_video"] = 1 };
                switch (Problem)
                {
                    case "missing": item.Remove("need_video"); break; case "string": item["need_video"] = "true"; break; case "number": item["need_video"] = 2; break;
                    case "negative": item["type"] = -1; break; case "zero": item["unit_id"] = 0; break; case "empty": item["filename"] = ""; break; case "photo-video": item["type"] = 0; break;
                }
                data = Problem == "duplicate" ? SynologyPhotosHttpFixture.List(item, (JsonObject)item.DeepClone()) : SynologyPhotosHttpFixture.List(item);
            }
            else if (call.Api.EndsWith("Browse.Item"))
            {
                var item = Http.PhotoJson(Media); item["filename"] = Photo.Filename; item["owner_user_id"] = Space == SynologyPhotoSpace.Shared ? 0 : 19; item["additional"] = Extra(8);
                if (Changed == "unit") item["additional"]!["thumbnail"]!["unit_id"] = 91;
                else if (Changed is "filename" or "type") item[Changed] = "changed";
                else if (Changed == "indexed_time") item[Changed] = item[Changed]!.GetValue<long>() + 1;
                else if (Changed is not null) item[Changed] = item[Changed]!.GetValue<int>() + 1;
                data = SynologyPhotosHttpFixture.List(item);
            }
            else if (call.Api.EndsWith("Browse.Unit"))
            {
                var first = new JsonObject { ["id"] = 81, ["filename"] = "synthetic.jpg", ["live_type"] = "photo", ["additional"] = Extra(81) };
                var second = new JsonObject { ["id"] = 82, ["filename"] = "synthetic.mp4", ["live_type"] = "video", ["additional"] = Extra(82) };
                if (Problem == "live-type") second["live_type"] = "unknown"; if (Problem == "live-thumb") second["additional"]!["thumbnail"]!["unit_id"] = 90;
                if (Problem == "live-filename") second["filename"] = ""; if (Problem == "live-duplicate") second = (JsonObject)first.DeepClone();
                data = SynologyPhotosHttpFixture.List(new JsonObject { ["id_item"] = Problem == "live-item" ? 8 : 7, ["unit"] = new JsonArray(first, second) });
            }
            else if (call.Api.EndsWith("Browse.Folder")) data = new JsonObject { ["folder"] = new JsonObject { ["id"] = 3, ["additional"] = new JsonObject { ["access_permission"] = new JsonObject { ["view"] = View, ["download"] = Download } } } };
            else throw new InvalidOperationException(call.Api);
            return Task.FromResult(SynologyPhotosHttpFixture.Json(data));
        }
        public void Dispose() => Http.Dispose();
    }
}
