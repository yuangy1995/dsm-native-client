using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.App.Features.Files.Settings;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Files.Settings;

public sealed class FileStationThemeTests
{
    internal static byte[] ImageBytes => Convert.FromBase64String("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGPQqDgBAAI0AWkYRiUPAAAAAElFTkSuQmCC");
    [Theory]
    [InlineData("FORM")][InlineData("JSON")]
    public async Task FullLayoutAndBothImageSequencesRequireReceiptAndReturnFreshBaseline(string format)
    {
        using var s = new Server(format); var old = await s.Repository.LoadFileStationThemeAsync();
        var logo = (await s.Repository.ListFileStationThemeImagesAsync(FileStationThemeImageKind.Logo))[0];
        var next = old with { CustomLogo = true, LogoImage = logo, CustomBackground = true, BackgroundImage = FileStationThemeImage.Defaults[9], Footer = "Hello & 世界" };
        var change = new FileStationSettingsChange(Guid.NewGuid(), old, next, true); var result = await s.Repository.SaveFileStationSettingAsync(change);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Outcome.Status); var saved = Assert.IsType<FileStationTheme>(result.Change.Desired);
        Assert.Null(saved.LogoImage); Assert.Null(saved.BackgroundImage); Assert.NotEqual(old.LogoSequence, saved.LogoSequence);
        var write = Assert.Single(s.Writes); Assert.Equal("history", s.Text(write["logo_type"])); Assert.Equal("logo.png", s.Text(write["logo_path"]));
        Assert.Equal("dsm7_010.jpg", s.Text(write["background_path"])); Assert.Equal("Hello & 世界", s.Text(write["footer_msg"]));
        foreach (var key in Server.Layout) Assert.Contains(key, write.Keys); Assert.Equal("1", write["version"]);
        await s.Repository.SaveFileStationSettingAsync(change); Assert.Single(s.Writes);
        var second = await s.Repository.SaveFileStationSettingAsync(new(Guid.NewGuid(), saved, saved with { Footer = "Next" }, true));
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, second.Outcome.Status); Assert.Equal(2, s.Writes.Count);
    }
    [Theory]
    [InlineData("missing-bool")][InlineData("string-bool")][InlineData("position")][InlineData("color")][InlineData("sequence")]
    public async Task MalformedThemeCannotBecomeDefaults(string fault)
    {
        using var s = new Server(); switch (fault) {
            case "missing-bool": s.Theme.Remove("enable_logo_customize"); break;
            case "string-bool": s.Theme["enable_logo_customize"] = "false"; break;
            case "position": s.Theme["logo_position"] = "unknown"; break;
            case "color": s.Theme["background_color"] = "red"; break;
            case "sequence": s.Theme["logo_seq"] = true; break; }
        await Assert.ThrowsAsync<InvalidDataException>(() => s.Repository.LoadFileStationThemeAsync()); Assert.Empty(s.Writes);
    }
    [Theory]
    [InlineData("new-logo")][InlineData("new-background")][InlineData("wrong-kind")][InlineData("footer")][InlineData("color")]
    [InlineData("path")][InlineData("foreign")][InlineData("unconfirmed")]
    public async Task InvalidDraftNeverWrites(string fault)
    {
        using var s = new Server(); var old = await s.Repository.LoadFileStationThemeAsync(); var next = old with { Footer = "Changed" };
        next = fault switch {
            "new-logo" => next with { CustomLogo = true }, "new-background" => next with { CustomBackground = true },
            "wrong-kind" => next with { CustomLogo = true, LogoImage = FileStationThemeImage.Defaults[0] },
            "footer" => next with { Footer = "line\nbreak" }, "color" => next with { BackgroundColor = "#12345g" },
            "path" => next with { CustomLogo = true, LogoImage = new(FileStationThemeImageKind.Logo, FileStationThemeImageSource.Nas, "/sample/../x.png", "x.png") },
            "foreign" => next with { ProfileId = Guid.NewGuid() }, _ => next };
        var result = await s.Repository.SaveFileStationSettingAsync(new(Guid.NewGuid(), old, next, fault != "unconfirmed"));
        Assert.False(result.Outcome.Submitted); Assert.Empty(s.Writes);
    }
    [Theory]
    [InlineData("lost")][InlineData("cancelled")][InlineData("read-fails")][InlineData("unchanged-logo")][InlineData("unchanged-background")][InlineData("missing-sequence")]
    public async Task UnknownSaveCannotClaimImagesOrReplayOnReopen(string failure)
    {
        using var s = new Server(); var old = await s.Repository.LoadFileStationThemeAsync(); s.Failure = failure;
        var next = old with { CustomLogo = true, LogoImage = new(FileStationThemeImageKind.Logo, FileStationThemeImageSource.History, "history/logo.png", "logo.png"),
            CustomBackground = true, BackgroundImage = FileStationThemeImage.Defaults[0] };
        var change = new FileStationSettingsChange(Guid.NewGuid(), old, next, true);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await s.Repository.SaveFileStationSettingAsync(change)).Outcome.Status);
        var repo = s.NewRepository(); await repo.SaveFileStationSettingAsync(change); await repo.SaveFileStationSettingAsync(change with { RequestId = Guid.NewGuid() }); Assert.Single(s.Writes);
        s.Failure = null; var review = await repo.ReviewFileStationSettingAsync(change.RequestId);
        Assert.Equal(failure == "read-fails" ? MutationResultStatus.ConfirmedSuccess : MutationResultStatus.SubmittedButUnverified, review!.Outcome.Status);
        Assert.Single(s.Writes);
    }
    [Theory]
    [InlineData("role")][InlineData("app")][InlineData("baseline")][InlineData("second-baseline")][InlineData("second-role")][InlineData("history")][InlineData("nas-denied")]
    public async Task PermissionsFreshBaselineAndImageIdentityAreCheckedBeforeSave(string fault)
    {
        using var s = new Server(); var old = await s.Repository.LoadFileStationThemeAsync(); var next = old with { Footer = "New" };
        if (fault == "role") s.Administrator = false; if (fault == "app") s.FileAccess = false;
        if (fault == "baseline") s.Theme["footer_msg"] = "Another client"; if (fault == "second-baseline") s.ChangeOnRead = 3;
        if (fault == "second-role") s.RevokeOnAccess = 2;
        if (fault == "history") { s.History.Clear(); next = next with { CustomLogo = true, LogoImage = new(FileStationThemeImageKind.Logo, FileStationThemeImageSource.History, "history/logo.png", "logo.png") }; }
        if (fault == "nas-denied") { s.NasReadAllowed = false; next = next with { CustomLogo = true, LogoImage = new(FileStationThemeImageKind.Logo, FileStationThemeImageSource.Nas, "/sample/logo.png", "logo.png") }; }
        var result = await s.Repository.SaveFileStationSettingAsync(new(Guid.NewGuid(), old, next, true)); Assert.False(result.Outcome.Submitted); Assert.Empty(s.Writes);
    }
    [Theory]
    [InlineData("FORM")][InlineData("JSON")]
    public async Task HistoryPreviewResolvesCurrentIndexAndNeverPutsAuthenticationInUrl(string format)
    {
        using var s = new Server(format); var image = (await s.Repository.ListFileStationThemeImagesAsync(FileStationThemeImageKind.Logo))[0]; s.History[0]!["index"] = 8;
        Assert.Equal(ImageBytes, await s.Repository.ReadFileStationThemeImageAsync(image));
        var get = s.Calls.Last(c => c.GetValueOrDefault("api") == Server.ImageApi && c["method"] == "get"); Assert.Equal("8", get["index"]); Assert.Equal("true", get["is_thumbnail"]);
        Assert.Equal("fbsharing_login_logo", s.Text(get["type"])); Assert.Equal("1", get["version"]);
        Assert.Equal(ImageBytes, await s.Repository.ReadFileStationThemeImageAsync(FileStationThemeImage.Defaults[9])); Assert.Equal(1, s.DefaultGets);
    }
    [Theory]
    [InlineData("duplicate-path")][InlineData("duplicate-index")][InlineData("negative-index")][InlineData("string-index")][InlineData("bad-extension")][InlineData("traversal")]
    public async Task HistoryListRejectsAmbiguousOrUnsafeIdentities(string fault)
    {
        using var s = new Server(); var row = s.History[0]!.AsObject();
        if (fault == "duplicate-path") s.History.Add(new JsonObject { ["index"] = 9, ["path"] = "history/logo.png" });
        if (fault == "duplicate-index") s.History.Add(new JsonObject { ["index"] = 0, ["path"] = "history/other.png" });
        if (fault == "negative-index") row["index"] = -1; if (fault == "string-index") row["index"] = "0";
        if (fault == "bad-extension") row["path"] = "history/logo.txt"; if (fault == "traversal") row["path"] = "history/../logo.png";
        await Assert.ThrowsAsync<InvalidDataException>(() => s.Repository.ListFileStationThemeImagesAsync(FileStationThemeImageKind.Logo));
    }
    [Fact]
    public async Task PreviewRejectsNonImagesEvenWithImageContentType()
    {
        using var s = new Server { InvalidBinary = true }; var image = (await s.Repository.ListFileStationThemeImagesAsync(FileStationThemeImageKind.Logo))[0];
        await Assert.ThrowsAnyAsync<Exception>(() => s.Repository.ReadFileStationThemeImageAsync(image)); Assert.Empty(s.Writes);
    }
    [Theory]
    [InlineData("FORM")][InlineData("JSON")]
    public async Task NasPreviewRequiresReadableExactFileAndUsesThumbVersionTwo(string format)
    {
        using var s = new Server(format); var image = new FileStationThemeImage(FileStationThemeImageKind.Logo, FileStationThemeImageSource.Nas, "/sample/logo.png", "logo.png");
        Assert.Equal(ImageBytes, await s.Repository.ReadFileStationThemeImageAsync(image));
        var get = s.Calls.Last(c => c.GetValueOrDefault("api") == "SYNO.FileStation.Thumb"); Assert.Equal("2", get["version"]);
        Assert.Equal(image.Path, s.Text(get["path"])); Assert.Equal("0", get["rotate"]);
        s.NasReadAllowed = false; await Assert.ThrowsAsync<InvalidDataException>(() => s.Repository.ReadFileStationThemeImageAsync(image));
    }
    [Theory]
    [InlineData("FORM")][InlineData("JSON")]
    public async Task UploadHasExactMultipartFieldAndDoesNotApplyTheme(string format)
    {
        using var s = new Server(format); var result = await s.Repository.UploadFileStationThemeImageAsync(FileStationThemeImageKind.Logo, "picture.png", ImageBytes, true);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Outcome.Status); Assert.Equal("history/uploaded.png", result.Image!.Path);
        Assert.Equal(1, s.Uploads); Assert.Empty(s.Writes); Assert.False(s.Theme["enable_logo_customize"]!.GetValue<bool>());
    }
    [Theory]
    [InlineData("lost")][InlineData("cancelled")][InlineData("http")][InlineData("malformed")][InlineData("no-path")][InlineData("no-history")][InlineData("history-fails")]
    public async Task UnknownUploadBlocksRenamedSameContentAcrossRepositories(string failure)
    {
        using var s = new Server { UploadFailure = failure };
        var result = await s.Repository.UploadFileStationThemeImageAsync(FileStationThemeImageKind.Logo, "one.png", ImageBytes, true);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, result.Outcome.Status); Assert.Null(result.Image);
        s.UploadFailure = null; var repo = s.NewRepository();
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await repo.UploadFileStationThemeImageAsync(FileStationThemeImageKind.Logo, "renamed.png", ImageBytes, true)).Outcome.Status); Assert.Equal(1, s.Uploads);
        var old = await repo.LoadFileStationThemeAsync(); Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await repo.SaveFileStationSettingAsync(new(Guid.NewGuid(), old, old with { Footer = "Independent" }, true))).Outcome.Status);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await repo.UploadFileStationThemeImageAsync(FileStationThemeImageKind.Background, "other-kind.png", ImageBytes, true)).Outcome.Status); Assert.Equal(2, s.Uploads);
    }
    [Fact]
    public async Task ExplicitUploadDenialAllowsNewExplicitAttemptWhileBadImagesNeverReachNetwork()
    {
        using var s = new Server { UploadFailure = "rejected" };
        Assert.Equal(MutationResultStatus.PermissionDenied, (await s.Repository.UploadFileStationThemeImageAsync(FileStationThemeImageKind.Logo, "one.png", ImageBytes, true)).Outcome.Status);
        s.UploadFailure = null; Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await s.Repository.UploadFileStationThemeImageAsync(FileStationThemeImageKind.Logo, "one.png", ImageBytes, true)).Outcome.Status);
        var calls = s.Calls.Count; foreach (var name in new[] { "../x.png", "x\".png", "x.txt", "x\r.png" })
            Assert.Equal(MutationErrorCategory.Validation, (await s.Repository.UploadFileStationThemeImageAsync(FileStationThemeImageKind.Logo, name, ImageBytes, true)).Outcome.ErrorCategory);
        Assert.Equal(MutationErrorCategory.Validation, (await s.Repository.UploadFileStationThemeImageAsync(FileStationThemeImageKind.Logo, "x.png", new byte[] { 1, 2, 3 }, true)).Outcome.ErrorCategory);
        Assert.Equal(calls, s.Calls.Count); Assert.Equal(2, s.Uploads);
    }
    [Fact]
    public async Task CancelBeforeUploadAndForeignSessionsDoNotDispatch()
    {
        using var s = new Server(); using var cancel = new CancellationTokenSource(); cancel.Cancel();
        Assert.Equal(MutationResultStatus.CancelledBeforeSubmission, (await s.Repository.UploadFileStationThemeImageAsync(FileStationThemeImageKind.Logo, "one.png", ImageBytes, true, cancel.Token)).Outcome.Status);
        var profile = new NasProfile(Guid.NewGuid(), "Example", "nas.invalid", null, "sample"); var session = new DsmSession(Guid.NewGuid(), "synthetic", null, null);
        var cap = new ApiCapability(Server.ImageApi, "entry.cgi", 1, 1, "FORM");
        Assert.False((await s.Api.UploadFileStationThemeImageAsync(profile, session, cap, FileStationThemeImageKind.Logo, "one.png", ImageBytes)).Submitted);
        await Assert.ThrowsAsync<ArgumentException>(() => s.Api.ReadBinaryAsync(profile, session, cap, "get", null, "image/", 1024));
        await Assert.ThrowsAsync<ArgumentException>(() => s.Api.ReadFileStationDefaultBackgroundAsync(profile, session, "dsm7_01.jpg", 1024));
        Assert.Empty(s.Calls); Assert.Equal(0, s.Uploads);
    }
    [Fact]
    public async Task ModelSelectsPreviewWithoutSavingAndCanEditAgainAfterVerifiedSave()
    {
        using var s = new Server(); using var model = new FileStationSettingsViewModel(s.Repository); await model.SelectSectionAsync(FileStationSettingsSection.Theme);
        var original = Assert.IsType<FileStationTheme>(model.Draft); model.UpdateDraft(original with { Footer = "Draft retained" });
        await model.OpenThemePickerAsync(FileStationThemeImageKind.Background); Assert.False(model.CanSave);
        await model.SetThemeSourceAsync(FileStationThemeImageSource.Default); Assert.Equal(10, model.ThemeImages.Count);
        await model.PreviewThemeImageAsync(model.ThemeImages[9]); Assert.True(model.CanUseThemeImage); model.UseThemeImage();
        Assert.False(model.ThemePickerOpen); Assert.Equal("Draft retained", Assert.IsType<FileStationTheme>(model.Draft).Footer); Assert.Empty(s.Writes);
        await model.SaveAsync(); Assert.Single(s.Writes); Assert.Null(Assert.IsType<FileStationTheme>(model.Draft).BackgroundImage);
        model.UpdateDraft(((FileStationTheme)model.Draft) with { Footer = "Next" }); await model.SaveAsync(); Assert.Equal(2, s.Writes.Count);
    }
    [Fact]
    public async Task ModelUploadRetainsDraftAndOnlyUsesReturnedHistoryIdentity()
    {
        using var s = new Server(); using var model = new FileStationSettingsViewModel(s.Repository); await model.SelectSectionAsync(FileStationSettingsSection.Theme);
        await model.OpenThemePickerAsync(FileStationThemeImageKind.Logo); await model.UploadThemeImageAsync("one.png", ImageBytes);
        Assert.Equal("FsThemeUploaded", model.ThemeMessageKey); Assert.True(model.CanUseThemeImage); Assert.Empty(s.Writes);
        model.UseThemeImage(); Assert.Equal("history/uploaded.png", Assert.IsType<FileStationTheme>(model.Draft).LogoImage!.Path); Assert.True(model.CanSave);
    }
    [Fact]
    public async Task ModelDropsLateImageAfterClosing()
    {
        using var s = new Server(); using var model = new FileStationSettingsViewModel(s.Repository); await model.SelectSectionAsync(FileStationSettingsSection.Theme);
        await model.OpenThemePickerAsync(FileStationThemeImageKind.Logo); s.BinaryBlock = new(TaskCreationOptions.RunContinuationsAsynchronously);
        var reading = model.PreviewThemeImageAsync(model.ThemeImages[0]); model.Dispose(); s.BinaryBlock.SetResult(); await reading;
        Assert.Null(model.ThemePreview); Assert.Null(model.ThemeSelection); Assert.False(model.CanUseThemeImage); Assert.Empty(s.Writes);
    }
    [Theory]
    [InlineData("FORM")][InlineData("JSON")]
    public async Task NasPickerReadsAllPagesNavigatesAndRetainsSettingsDraft(string format)
    {
        using var s = new Server(format); using var model = new FileStationSettingsViewModel(s.Repository); await model.SelectSectionAsync(FileStationSettingsSection.Theme);
        model.UpdateDraft(((FileStationTheme)model.Draft!) with { Footer = "Retained" });
        await model.OpenThemePickerAsync(FileStationThemeImageKind.Logo); await model.SetThemeSourceAsync(FileStationThemeImageSource.Nas);
        Assert.Null(model.ThemeMessageKey); Assert.Equal(201, model.ThemeFiles.Count);
        Assert.Equal(new[] { "0", "200" }, s.Calls.Where(v => v["method"] == "list_share").Select(v => v["offset"]));
        await model.NavigateThemeFolderAsync(model.ThemeFiles[0]); Assert.Equal("/sample", model.ThemeFolder);
        await model.PreviewThemeFileAsync(Assert.Single(model.ThemeFiles)); Assert.True(model.CanUseThemeImage); model.UseThemeImage();
        var draft = Assert.IsType<FileStationTheme>(model.Draft); Assert.Equal("Retained", draft.Footer); Assert.Equal("/sample/logo.png", draft.LogoImage!.Path); Assert.Empty(s.Writes);
    }
    [Theory]
    [InlineData("duplicate")][InlineData("total")][InlineData("outside")]
    public async Task IncompleteNasPickerCannotOfferPartialSelection(string fault)
    {
        using var s = new Server { FolderFault = fault }; using var model = new FileStationSettingsViewModel(s.Repository); await model.SelectSectionAsync(FileStationSettingsSection.Theme);
        await model.OpenThemePickerAsync(FileStationThemeImageKind.Logo); await model.SetThemeSourceAsync(FileStationThemeImageSource.Nas);
        Assert.Equal("FsThemeLoadFailed", model.ThemeMessageKey); Assert.Empty(model.ThemeFiles); Assert.False(model.CanUseThemeImage);
    }

    private sealed class Server : HttpMessageHandler
    {
        public const string ThemeApi = "SYNO.Core.Theme.FileSharingLogin", ImageApi = "SYNO.Core.Theme.Image";
        public static readonly string[] Layout = ["enable_logo_customize", "logo_position", "enable_background_customize", "background_position", "background_color", "footer_msg", "enable_footer_html"];
        private readonly HttpClient _http; private readonly string _format; private readonly Guid _id = Guid.NewGuid();
        public DsmApiClient Api { get; } public DsmRepository Repository { get; }
        public JsonObject Theme = JsonNode.Parse("""{"enable_logo_customize":false,"logo_position":"rightup","enable_background_customize":false,"background_position":"fill","background_color":"#123456","footer_msg":"","enable_footer_html":false,"logo_seq":1,"background_seq":"initial"}""")!.AsObject();
        public JsonArray History = [new JsonObject { ["index"] = 0, ["path"] = "history/logo.png", ["filename"] = "Logo" }];
        public List<Dictionary<string, string>> Calls = [], Writes = [];
        public string? Failure, UploadFailure, FolderFault; public bool Administrator = true, FileAccess = true, NasReadAllowed = true, InvalidBinary;
        public int Reads, AccessReads, ChangeOnRead, RevokeOnAccess, Uploads, DefaultGets; public TaskCompletionSource? BinaryBlock;
        public Server(string format = "FORM") { _format = format; _http = new(this, false); Api = new(_http); Repository = NewRepository(); }
        public DsmRepository NewRepository() => new(new(_id, "Example", "nas.invalid", null, "sample"), new(_id, "synthetic-session", "synthetic-token", null), Api,
            new[] { ThemeApi, ImageApi, "SYNO.Core.Desktop.Initdata", "SYNO.FileStation.List", "SYNO.FileStation.Thumb" }.ToDictionary(a => a, a => new ApiCapability(a, "entry.cgi", 1, 9, _format)));
        public string Text(string value) => _format == "JSON" ? JsonSerializer.Deserialize<string>(value)! : value;
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
        {
            Assert.DoesNotContain("synthetic-session", request.RequestUri!.AbsoluteUri); Assert.DoesNotContain("synthetic-token", request.RequestUri.AbsoluteUri);
            if (request.RequestUri.AbsolutePath.StartsWith("/webman/", StringComparison.Ordinal))
            { Assert.Equal("/webman/resources/images/1x/default_login_background/dsm7_010.jpg", request.RequestUri.AbsolutePath); Assert.False(request.Headers.Contains("Cookie")); DefaultGets++; return Binary(); }
            if (request.Content?.Headers.ContentType?.MediaType == "multipart/form-data")
            {
                var bytes = await request.Content.ReadAsByteArrayAsync(token); Assert.Equal(bytes.Length, request.Content.Headers.ContentLength); var body = Encoding.UTF8.GetString(bytes);
                Assert.Contains("name=\"upload_image\"; filename=\"", body); Assert.DoesNotContain("name=\"file\"", body); Assert.Contains("name=\"version\"\r\n\r\n1\r\n", body);
                Assert.Contains("name=\"type\"\r\n\r\nfbsharing_login_", body); Assert.Equal("id=synthetic-session", Assert.Single(request.Headers.GetValues("Cookie")));
                Uploads++;
                if (UploadFailure == "rejected") return Reject();
                if (UploadFailure == "lost") throw new HttpRequestException("synthetic lost upload receipt");
                if (UploadFailure == "cancelled") throw new OperationCanceledException();
                if (UploadFailure == "http") return new(HttpStatusCode.BadGateway);
                if (UploadFailure == "malformed") return new(HttpStatusCode.OK) { Content = new StringContent("invalid") };
                if (UploadFailure != "no-history" && !History.Any(r => r!["path"]!.GetValue<string>() == "history/uploaded.png")) History.Add(new JsonObject { ["index"] = 3, ["path"] = "history/uploaded.png" });
                return Reply(UploadFailure == "no-path" ? new() : new() { ["path"] = "history/uploaded.png" });
            }
            var raw = request.Method == HttpMethod.Get ? request.RequestUri.Query.TrimStart('?') : await request.Content!.ReadAsStringAsync(token);
            var fields = raw.Split('&').Select(v => v.Split('=', 2)).ToDictionary(v => WebUtility.UrlDecode(v[0]), v => WebUtility.UrlDecode(v[1])); Calls.Add(fields);
            var api = fields["api"]; var method = fields["method"]; Assert.Equal(api is "SYNO.FileStation.List" or "SYNO.FileStation.Thumb" ? "2" : "1", fields["version"]);
            if (api == "SYNO.Core.Desktop.Initdata") { AccessReads++; return Reply(new() { ["Session"] = new JsonObject { ["is_admin"] = Administrator && (RevokeOnAccess == 0 || AccessReads < RevokeOnAccess), ["isLogined"] = true }, ["AppPrivilege"] = new JsonObject { ["SYNO.SDS.App.FileStation3.Instance"] = FileAccess } }); }
            if (api == ThemeApi)
            {
                if (method == "set")
                {
                    Writes.Add(fields);
                    foreach (var key in Layout) Theme[key] = key.StartsWith("enable_") ? JsonValue.Create(bool.Parse(fields[key])) : JsonValue.Create(Text(fields[key]));
                    if (fields.ContainsKey("logo_path") && Failure != "unchanged-logo") Theme["logo_seq"] = Failure == "missing-sequence" ? null : "new-logo";
                    if (fields.ContainsKey("background_path") && Failure != "unchanged-background") Theme["background_seq"] = "new-background";
                    if (Failure == "lost") throw new HttpRequestException("synthetic lost receipt"); if (Failure == "cancelled") throw new OperationCanceledException();
                    return Reply(new());
                }
                Reads++; if (Failure == "read-fails" && Writes.Count > 0) throw new HttpRequestException("synthetic read failure");
                if (ChangeOnRead == Reads) Theme["footer_msg"] = "Changed externally"; return Reply(Theme.DeepClone().AsObject());
            }
            if (api == ImageApi && method == "list")
            { if (UploadFailure == "history-fails" && Uploads > 0) throw new HttpRequestException("synthetic history failure"); return Reply(new() { ["list"] = History.DeepClone() }); }
            if (api == "SYNO.FileStation.List")
            {
                if (method is "list_share" or "list")
                {
                    Assert.Equal("name", Text(fields["sort_by"])); Assert.Equal("asc", Text(fields["sort_direction"]));
                    var offset = int.Parse(fields["offset"]); var count = method == "list_share" ? 201 : 1; var rows = new JsonArray();
                    if (method == "list") Assert.Equal("/sample", Text(fields["folder_path"]));
                    for (var i = offset; i < Math.Min(count, offset + 200); i++)
                    {
                        var name = method == "list" ? "logo.png" : i == 0 || FolderFault == "duplicate" && i == 200 ? "sample" : "folder-" + i;
                        rows.Add(new JsonObject { ["path"] = (method == "list" ? "/sample/" : FolderFault == "outside" ? "/outside/" : "/") + name, ["name"] = name, ["isdir"] = method == "list_share", ["size"] = ImageBytes.Length });
                    }
                    return Reply(new() { [method == "list" ? "files" : "shares"] = rows, ["offset"] = offset, ["total"] = FolderFault == "total" && offset > 0 ? count + 1 : count });
                }
                Assert.Equal("getinfo", method); Assert.Equal("/sample/logo.png", JsonSerializer.Deserialize<string[]>(fields["path"])![0]);
                return Reply(new() { ["files"] = new JsonArray(new JsonObject { ["path"] = "/sample/logo.png", ["name"] = "logo.png", ["isdir"] = false,
                    ["additional"] = new JsonObject { ["perm"] = new JsonObject { ["read"] = NasReadAllowed } } }) });
            }
            if (api == ImageApi && method == "get" || api == "SYNO.FileStation.Thumb")
            {
                Assert.Equal(HttpMethod.Get, request.Method); Assert.Equal("id=synthetic-session", Assert.Single(request.Headers.GetValues("Cookie")));
                if (BinaryBlock is not null) await BinaryBlock.Task; return Binary();
            }
            throw new InvalidOperationException("unexpected synthetic request");
        }
        private HttpResponseMessage Binary()
        { var response = new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(InvalidBinary ? [1, 2, 3] : ImageBytes) }; response.Content.Headers.ContentType = new("image/png"); return response; }
        private static HttpResponseMessage Reply(JsonObject data) => new(HttpStatusCode.OK) { Content = new StringContent(new JsonObject { ["success"] = true, ["data"] = data }.ToJsonString()) };
        private static HttpResponseMessage Reject() => new(HttpStatusCode.OK) { Content = new StringContent("""{"success":false,"error":{"code":105}}""") };
        protected override void Dispose(bool disposing) { if (disposing) _http.Dispose(); base.Dispose(disposing); }
    }
}
