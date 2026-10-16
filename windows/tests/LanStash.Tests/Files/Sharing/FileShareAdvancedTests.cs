using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.App.Features.Files.Sharing;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Files.Sharing;

public sealed class FileShareAdvancedTests
{
    private static readonly Guid ProfileId = Guid.Parse("11111111-1111-1111-1111-111111111111");

    [Theory]
    [InlineData("FORM")]
    [InlineData("JSON")]
    public async Task NamedMembersUseBoundGetPermissionAndFullSetsWithNewDifferences(string format)
    {
        using var server = new ShareServer(format);
        server.Link["protect_type"] = "user";
        server.Link["protect_users"] = new JsonArray("existing");
        var baseline = await server.Baseline();
        var result = await server.Repository.EditFileShareLinkAsync(new(baseline)
        {
            Advanced = new()
            {
                Audience = FileShareAudienceIntent.Principals, AudienceChangeConfirmed = true,
                Principals = [new("existing", FileSharePrincipalKind.User), new("new-user", FileSharePrincipalKind.User),
                    new("team", FileSharePrincipalKind.Group)], MaximumAccesses = 12,
            },
        });
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Result.Status);
        var write = Assert.Single(server.Requests, item => item.Method == "edit");
        Assert.Equal("[\"existing\",\"new-user\"]", write.Values["protect_users"]);
        Assert.Equal("[\"new-user\"]", write.Values["new_protect_users"]);
        Assert.Equal("[\"team\"]", write.Values["protect_groups"]);
        Assert.Equal("[\"team\"]", write.Values["new_protect_groups"]);
        Assert.Equal("12", write.Values["expire_times"]);
        Assert.DoesNotContain("password", write.Values.Keys);
        Assert.DoesNotContain("date_available", write.Values.Keys);
        Assert.DoesNotContain("date_expired", write.Values.Keys);
        var access = Assert.Single(server.Requests, item => item.Api == "SYNO.Core.Desktop.Initdata");
        Assert.Equal(HttpMethod.Get, access.HttpMethod);
        Assert.Equal("null", access.Values["launch_app"]);
        Assert.DoesNotContain("_sid", access.Values.Keys);
        Assert.DoesNotContain("SynoToken", access.Values.Keys);
        Assert.True(access.HasCookie);
        Assert.True(access.HasTokenHeader);
        Assert.Equal(3, server.Requests.Count(item => item.Method == "list"));
    }

    [Theory]
    [InlineData("FORM")]
    [InlineData("JSON")]
    public async Task PasswordReplacePreservesOriginalDateTimeAndWhitespace(string format)
    {
        using var server = new ShareServer(format);
        server.Link["date_available"] = "2026-10-01 10:11:12";
        server.Link["date_expired"] = "2026-12-01 16:17:18";
        var baseline = await server.Baseline();
        var outcome = await server.Repository.EditFileShareLinkAsync(new(baseline)
        { PasswordIntent = FileShareValueIntent.Replace, Password = " secret " });
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, outcome.Result.Status);
        Assert.Equal("2026-12-01 16:17:18", outcome.Link?.RawExpiryDate);
        var edit = Assert.Single(server.Requests, item => item.Method == "edit");
        Assert.Equal(format == "JSON" ? "\" secret \"" : " secret ", edit.Values["password"]);
        Assert.DoesNotContain("date_expired", edit.Values.Keys);
        Assert.DoesNotContain("date_available", edit.Values.Keys);
        Assert.DoesNotContain(server.Requests, item => item.Api == "SYNO.Core.Desktop.Initdata");
    }

    [Fact]
    public async Task LostPasswordReceiptStaysUnknownEvenWhenPasswordFlagIsTrueAndBlocksOtherWrites()
    {
        using var server = new ShareServer();
        server.LoseEditReceipt = true;
        var baseline = await server.Baseline();
        var request = new EditFileShareLinkRequest(baseline) { PasswordIntent = FileShareValueIntent.Replace, Password = "new-secret" };
        var first = await server.Repository.EditFileShareLinkAsync(request);
        var review = await server.Repository.ReviewFileShareLinkEditAsync(baseline.Id);
        var duplicate = await server.NewRepository().EditFileShareLinkAsync(request);
        var deletion = await server.NewRepository().DeleteFileShareLinkAsync(new(baseline));
        var creation = await server.NewRepository().CreateFileShareLinkAsync(new(Target()));
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, first.Result.Status);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, review.Result.Status);
        Assert.Equal(MutationErrorCategory.Conflict, duplicate.Result.ErrorCategory);
        Assert.Equal(MutationErrorCategory.Conflict, deletion.Result.ErrorCategory);
        Assert.Equal(MutationErrorCategory.Conflict, creation.Result.ErrorCategory);
        Assert.Equal(1, server.EditCount);
        Assert.DoesNotContain("new-secret", request.ToString());
    }

    [Fact]
    public async Task AcceptedEditWithFailedReadCanRecoverWithoutResubmission()
    {
        using var server = new ShareServer();
        server.FailReadAfterEdit = true;
        var baseline = await server.Baseline();
        var first = await server.Repository.EditFileShareLinkAsync(new(baseline)
        { PasswordIntent = FileShareValueIntent.Replace, Password = "new-secret" });
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, first.Result.Status);
        server.FailReadAfterEdit = false;
        var review = await server.NewRepository().ReviewFileShareLinkEditAsync(baseline.Id);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, review.Result.Status);
        Assert.Equal(1, server.EditCount);
    }

    [Fact]
    public async Task DatesHaveIndependentKeepReplaceAndClearIntents()
    {
        using var server = new ShareServer();
        server.Link["date_available"] = "2026-10-01 10:11:12";
        server.Link["date_expired"] = "2026-12-01 16:17:18";
        var baseline = await server.Baseline();
        var outcome = await server.Repository.EditFileShareLinkAsync(new(baseline)
        {
            AvailableDateIntent = FileShareValueIntent.Clear,
            ExpiryDateIntent = FileShareValueIntent.Replace, ExpiresOn = new(2027, 1, 1),
        });
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, outcome.Result.Status);
        var edit = Assert.Single(server.Requests, item => item.Method == "edit");
        Assert.Equal("0", edit.Values["date_available"]);
        Assert.Equal("2027-01-01", edit.Values["date_expired"]);
        Assert.DoesNotContain("password", edit.Values.Keys);
    }

    [Theory]
    [InlineData(false, false)]
    [InlineData(true, false)]
    [InlineData(false, true)]
    public async Task InvalidAudienceOrPasswordIntentMakesNoWrite(bool clearPassword, bool emptyMembers)
    {
        using var server = new ShareServer();
        server.Link["has_password"] = true;
        server.Link["protect_type"] = "password";
        var baseline = await server.Baseline();
        var request = clearPassword
            ? new EditFileShareLinkRequest(baseline) { PasswordIntent = FileShareValueIntent.Clear }
            : new EditFileShareLinkRequest(baseline)
            {
                Advanced = new()
                {
                    Audience = emptyMembers ? FileShareAudienceIntent.Principals : FileShareAudienceIntent.Anyone,
                    AudienceChangeConfirmed = emptyMembers,
                },
            };
        var outcome = await server.Repository.EditFileShareLinkAsync(request);
        Assert.Equal(MutationErrorCategory.Validation, outcome.Result.ErrorCategory);
        Assert.Empty(server.Requests);
        Assert.Equal(0, server.EditCount);
    }

    [Fact]
    public async Task AdvancedPermissionRevocationMakesNoWrite()
    {
        using var server = new ShareServer();
        server.HasAccess = false;
        var baseline = await server.Baseline();
        var outcome = await server.Repository.EditFileShareLinkAsync(new(baseline)
        { Advanced = new() { MaximumAccesses = 20 } });
        Assert.Equal(MutationResultStatus.PermissionDenied, outcome.Result.Status);
        Assert.Equal(0, server.EditCount);
        Assert.DoesNotContain(server.Requests, item => item.Api.StartsWith("SYNO.Core.System", StringComparison.Ordinal));
    }

    [Fact]
    public async Task MemberLookupThenBaselineChangeMakesNoWrite()
    {
        using var server = new ShareServer();
        server.ChangeDuringMemberRead = true;
        var baseline = await server.Baseline();
        var outcome = await server.Repository.EditFileShareLinkAsync(new(baseline)
        {
            Advanced = new() { Audience = FileShareAudienceIntent.Principals, AudienceChangeConfirmed = true,
                Principals = [new("existing", FileSharePrincipalKind.User)] },
        });
        Assert.Equal(MutationErrorCategory.Conflict, outcome.Result.ErrorCategory);
        Assert.Equal(0, server.EditCount);
    }

    [Theory]
    [InlineData("", 0)]
    [InlineData("0", 0)]
    [InlineData("2026-12-01 16:17:18", 1)]
    public async Task ListPreservesObservedEmptyAndDateTimeForms(string raw, int expectedDate)
    {
        using var server = new ShareServer();
        server.Link["date_expired"] = raw;
        server.Link["path"] = "/share/folder ";
        var link = await server.Baseline();
        Assert.Equal(expectedDate == 0 ? null : new DateOnly(2026, 12, 1), link.ExpiresOn);
        Assert.Equal(expectedDate == 0 ? null : raw, link.RawExpiryDate);
        Assert.Equal("/share/folder ", link.Path);
    }

    [Theory]
    [InlineData("protect_users")]
    [InlineData("enable_upload")]
    [InlineData("project_name")]
    public async Task MissingAdvancedFieldLeavesBasicListReadableAndRejectsAdvancedWrite(string field)
    {
        using var server = new ShareServer();
        server.Link.Remove(field);
        var baseline = await server.Baseline();
        Assert.Null(baseline.Advanced);
        var result = await server.Repository.EditFileShareLinkAsync(new(baseline) { Advanced = new() { MaximumAccesses = 4 } });
        Assert.Equal(MutationErrorCategory.Validation, result.Result.ErrorCategory);
        Assert.Equal(0, server.EditCount);
    }

    [Theory]
    [InlineData("FORM")]
    [InlineData("JSON")]
    public async Task FileCollectionUsesConfirmedWritableDirectoryAndNeverWritesEnableUpload(string format)
    {
        using var server = new ShareServer(format);
        server.HasLink = false;
        var result = await server.Repository.CreateFileShareLinkAsync(new(Target(), " secret ", new(2027, 1, 1))
        { AvailableOn = new(2026, 11, 1), FileRequest = new(" collection ", " message ", true) });
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Result.Status);
        Assert.True(result.Link?.Advanced?.IsFileRequest);
        var create = Assert.Single(server.Requests, item => item.Method == "create");
        Assert.Equal("true", create.Values["file_request"]);
        Assert.Equal(format == "JSON" ? "\" collection \"" : " collection ", create.Values["request_name"]);
        Assert.DoesNotContain("enable_upload", create.Values.Keys);
        var edit = await server.Repository.EditFileShareLinkAsync(new(result.Link!)
        { Advanced = new() { RequestName = "new title", RequestMessage = "new message" } });
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, edit.Result.Status);
        var write = Assert.Single(server.Requests, item => item.Method == "edit");
        Assert.Equal("true", write.Values["file_request"]);
        Assert.DoesNotContain("enable_upload", write.Values.Keys);
    }

    [Theory]
    [InlineData(false, true)]
    [InlineData(true, false)]
    public async Task CollectionWithoutConfirmationOrWritePermissionMakesNoCreate(bool confirmed, bool writable)
    {
        using var server = new ShareServer();
        server.CanWrite = writable;
        var result = await server.Repository.CreateFileShareLinkAsync(new(Target()) { FileRequest = new("title", "", confirmed) });
        Assert.NotEqual(MutationResultStatus.ConfirmedSuccess, result.Result.Status);
        Assert.False(result.Result.Submitted);
        Assert.DoesNotContain(server.Requests, item => item.Method == "create");
    }

    [Fact]
    public async Task CreationWithoutReceiptIdNeverClaimsSamePathAndKeepsWorkspaceLock()
    {
        using var server = new ShareServer();
        server.HasLink = false;
        server.OmitCreateId = true;
        var first = await server.Repository.CreateFileShareLinkAsync(new(Target()));
        var second = await server.NewRepository().CreateFileShareLinkAsync(new(Target()));
        var review = await server.Repository.ReviewFileShareLinkCreationAsync(Target().Path);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, first.Result.Status);
        Assert.Equal(MutationErrorCategory.Conflict, second.Result.ErrorCategory);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, review.Result.Status);
        Assert.Single(server.Requests, item => item.Method == "create");
    }

    [Fact]
    public async Task PendingEditCannotBeReviewedByAnotherAccountUsingTheSameProfileId()
    {
        using var server = new ShareServer();
        var baseline = await server.Baseline();
        server.LoseEditReceipt = true;
        await server.Repository.EditFileShareLinkAsync(new(baseline)
        { PasswordIntent = FileShareValueIntent.Replace, Password = "new-secret" });
        server.Requests.Clear();
        var result = await server.NewRepository("different-user").ReviewFileShareLinkEditAsync(baseline.Id);
        Assert.False(result.Result.Submitted);
        Assert.Equal(MutationErrorCategory.Conflict, result.Result.ErrorCategory);
        Assert.Empty(server.Requests);
    }

    [Fact]
    public async Task UnknownAvailabilityFieldKeepsListReadableButPreventsUnverifiableEdit()
    {
        using var server = new ShareServer();
        server.Link.Remove("date_available");
        var baseline = await server.Baseline();
        Assert.False(baseline.AvailabilityDateKnown);
        var result = await server.Repository.EditFileShareLinkAsync(new(baseline)
        { ExpiryDateIntent = FileShareValueIntent.Clear });
        Assert.Equal(MutationResultStatus.Unsupported, result.Result.Status);
        Assert.False(result.Result.Submitted);
        Assert.Equal(0, server.EditCount);
    }

    [Fact]
    public async Task CancelledEditMakesZeroRequests()
    {
        using var server = new ShareServer();
        var baseline = await server.Baseline();
        using var cancellation = new CancellationTokenSource(); cancellation.Cancel();
        var result = await server.Repository.EditFileShareLinkAsync(new(baseline)
        { ExpiryDateIntent = FileShareValueIntent.Clear }, cancellation.Token);
        Assert.Equal(MutationResultStatus.CancelledBeforeSubmission, result.Result.Status);
        Assert.Empty(server.Requests);
    }

    [Fact]
    public async Task MembersReadAllPagesWithoutDroppingSameNameDifferentKind()
    {
        using var server = new ShareServer();
        server.Principals = Enumerable.Range(0, 401).Select(index => new FileSharePrincipal($"user-{index}", FileSharePrincipalKind.User))
            .Append(new("user-0", FileSharePrincipalKind.Group)).ToArray();
        var result = await server.Repository.ListFileSharePrincipalsAsync("");
        Assert.Equal(402, result.Count);
        Assert.Equal(["0", "200", "400"], server.Requests.Select(item => item.Values["offset"]));
    }

    [Fact]
    public async Task BatchEditStopsAtUnknownAndContinuesOnlyAfterExplicitReviewAndClick()
    {
        var links = Enumerable.Range(0, 3).Select(index => new FileShareLink($"link-{index}", $"/share/{index}",
            new Uri($"https://share.invalid/{index}"), false, null)).ToArray();
        var repo = new EditRepository(links);
        using var model = new FileShareLinkEditViewModel(repo, ProfileId, links) { ExpiryDateIntent = FileShareValueIntent.Replace, ExpiresOn = new(2027, 1, 1) };
        await model.SaveAsync();
        Assert.Equal(2, repo.Edits);
        Assert.True(model.CanReview);
        Assert.False(model.CanSave);
        Assert.Null(model.Results[2].Result);
        await model.ReviewAsync();
        Assert.Equal(2, repo.Edits);
        Assert.True(model.CanSave);
        await model.SaveAsync();
        Assert.Equal(3, repo.Edits);
        Assert.True(model.IsComplete);
    }

    [Fact]
    public void EditingOnlyStartDateStillChecksKeptExpirationAndDisplaysRecovery()
    {
        var link = new FileShareLink("one", "/share/one", new("https://share.invalid/one"), false, new(2026, 12, 1));
        using var model = new FileShareLinkEditViewModel(new EditRepository([link]), ProfileId, [link])
        { AvailableDateIntent = FileShareValueIntent.Replace, AvailableOn = new(2027, 1, 1) };
        Assert.False(model.CanSave);
        Assert.Equal("FileShareDateRangeError", model.ValidationMessageKey);
        model.AvailableOn = new(2026, 11, 1);
        Assert.True(model.CanSave);
        Assert.Null(model.ValidationMessageKey);
    }

    [Fact]
    public async Task MemberLookupIgnoresLateReplyAndDisposalDropsLateEditResult()
    {
        var link = new FileShareLink("one", "/share/one", new("https://share.invalid/one"), false, null);
        var repo = new EditRepository([link]);
        using var model = new FileShareLinkEditViewModel(repo, ProfileId, [link]);
        var first = model.LoadMembersAsync("old");
        var second = model.LoadMembersAsync("new");
        repo.MemberReads["new"].SetResult([new("new", FileSharePrincipalKind.User)]);
        await second;
        repo.MemberReads["old"].SetResult([new("old", FileSharePrincipalKind.User)]);
        await first;
        Assert.Equal("new", Assert.Single(model.Members).Name);
        repo.DeferredEdit = new(TaskCreationOptions.RunContinuationsAsynchronously);
        model.ExpiryDateIntent = FileShareValueIntent.Clear;
        var edit = model.SaveAsync();
        model.Dispose();
        repo.DeferredEdit.SetResult(new(Success("shareLinkEdit"), link));
        await edit;
        Assert.Null(model.Results[0].Result);
    }

    private static MutationResult Success(string operation) => new(1, MutationResultStatus.ConfirmedSuccess,
        operation, true, false, new(1, 0, 0));
    private static FileShareLinkTarget Target() => new(ProfileId, "/share/folder", "folder", true, 0, null, "tester", true, true);

    private sealed class EditRepository(FileShareLink[] links) : IFileShareLinkRepository
    {
        public Guid ProfileId => FileShareAdvancedTests.ProfileId;
        public FileShareLinkAvailability ShareLinkAvailability => new(FileShareLinkAvailabilityStatus.Available, 3);
        public int Edits { get; private set; }
        public Dictionary<string, TaskCompletionSource<IReadOnlyList<FileSharePrincipal>>> MemberReads { get; } = [];
        public TaskCompletionSource<FileShareLinkEditOutcome>? DeferredEdit { get; set; }
        public Task<FileShareLinkCreationOutcome> CreateFileShareLinkAsync(CreateFileShareLinkRequest request, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<IReadOnlyList<FileSharePrincipal>> ListFileSharePrincipalsAsync(string prefix, CancellationToken cancellationToken = default)
        {
            var completion = new TaskCompletionSource<IReadOnlyList<FileSharePrincipal>>(TaskCreationOptions.RunContinuationsAsynchronously);
            MemberReads[prefix] = completion; return completion.Task;
        }
        public Task<FileShareLinkEditOutcome> EditFileShareLinkAsync(EditFileShareLinkRequest request, CancellationToken cancellationToken = default)
        {
            Edits++;
            if (DeferredEdit is not null) return DeferredEdit.Task;
            return Task.FromResult(Edits == 2
                ? new FileShareLinkEditOutcome(new(1, MutationResultStatus.SubmittedButUnverified, "shareLinkEdit", true, true, new(0, 0, 1)))
                : new FileShareLinkEditOutcome(Success("shareLinkEdit"), request.Link));
        }
        public Task<FileShareLinkEditOutcome> ReviewFileShareLinkEditAsync(string id, CancellationToken cancellationToken = default) =>
            Task.FromResult(new FileShareLinkEditOutcome(Success("shareLinkEdit"), links.Single(link => link.Id == id)));
    }

    private sealed record Request(string Api, string Method, HttpMethod HttpMethod, Dictionary<string, string> Values, bool HasCookie, bool HasTokenHeader);

    private sealed class ShareServer : HttpMessageHandler
    {
        private readonly string _format;
        private readonly DsmApiClient _client;
        private readonly NasProfile _profile = new(ProfileId, "Synthetic", "nas.invalid", 5001, "tester");
        private readonly DsmSession _session = new(ProfileId, "synthetic-sid", "synthetic-token", null);
        public DsmRepository Repository { get; }
        public List<Request> Requests { get; } = [];
        public bool HasLink { get; set; } = true;
        public bool HasAccess { get; set; } = true;
        public bool CanWrite { get; set; } = true;
        public bool LoseEditReceipt { get; set; }
        public bool FailReadAfterEdit { get; set; }
        public bool ChangeDuringMemberRead { get; set; }
        public bool OmitCreateId { get; set; }
        public int EditCount { get; private set; }
        public FileSharePrincipal[] Principals { get; set; } = [new("existing", FileSharePrincipalKind.User), new("new-user", FileSharePrincipalKind.User), new("team", FileSharePrincipalKind.Group)];
        public JsonObject Link { get; } = new()
        {
            ["id"] = "one", ["path"] = "/share/folder", ["url"] = "https://share.invalid/one", ["has_password"] = false,
            ["date_available"] = "", ["date_expired"] = "", ["protect_type"] = "none", ["protect_users"] = new JsonArray(),
            ["protect_groups"] = new JsonArray(), ["expire_times"] = 0, ["enable_upload"] = false,
            ["project_name"] = "SYNO.SDS.App.FileStation3.Instance", ["request_name"] = "", ["request_info"] = "",
        };
        public ShareServer(string format = "FORM")
        {
            _format = format; _client = new(new HttpClient(this)); Repository = NewRepository();
        }
        public DsmRepository NewRepository(string? username = null) => new(
            username is null ? _profile : _profile with { Username = username }, _session, _client,
            new[] { new ApiCapability("SYNO.FileStation.Sharing", "entry.cgi", 3, 9, _format),
                new ApiCapability("SYNO.FileStation.List", "entry.cgi", 2, 2, _format),
                new ApiCapability("SYNO.FileStation.UserGrp", "entry.cgi", 1, 1, _format),
                new ApiCapability("SYNO.Core.Desktop.Initdata", "entry.cgi", 1, 1, _format) }.ToDictionary(item => item.Name));
        public async Task<FileShareLink> Baseline()
        {
            var link = Assert.Single(await Repository.ListFileShareLinksAsync()); Requests.Clear(); return link;
        }
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var text = request.Method == HttpMethod.Get ? request.RequestUri!.Query.TrimStart('?') :
                await request.Content!.ReadAsStringAsync(cancellationToken);
            var values = text.Split('&', StringSplitOptions.RemoveEmptyEntries).Select(value => value.Split('=', 2))
                .ToDictionary(value => Uri.UnescapeDataString(value[0].Replace('+', ' ')), value => Uri.UnescapeDataString(value[1].Replace('+', ' ')));
            var api = values["api"]; var method = values["method"];
            Requests.Add(new(api, method, request.Method, values, request.Headers.Contains("Cookie"), request.Headers.Contains("X-SYNO-TOKEN")));
            string Scalar(string key) => _format == "JSON" ? JsonSerializer.Deserialize<string>(values[key])! : values[key];
            JsonObject data;
            if (api == "SYNO.Core.Desktop.Initdata")
                data = new() { ["Session"] = new JsonObject { ["isLogined"] = true }, ["AppPrivilege"] = new JsonObject { ["SYNO.SDS.App.FileStation3.Instance"] = HasAccess } };
            else if (api == "SYNO.FileStation.UserGrp")
            {
                var members = Principals.Where(item => item.Name.StartsWith(Scalar("prefix"), StringComparison.Ordinal)).ToArray();
                var offset = int.Parse(values["offset"], System.Globalization.CultureInfo.InvariantCulture);
                data = new() { ["total"] = members.Length, ["owners"] = new JsonArray(members.Skip(offset).Take(200).Select(item => (JsonNode)new JsonObject
                    { ["name"] = item.Name, ["type"] = item.Kind == FileSharePrincipalKind.User ? "user" : "group" }).ToArray()) };
                if (ChangeDuringMemberRead) Link["date_expired"] = "2027-02-01";
            }
            else if (method == "getinfo")
                data = new() { ["files"] = new JsonArray(new JsonObject { ["path"] = "/share/folder", ["name"] = "folder", ["isdir"] = true,
                    ["additional"] = new JsonObject { ["owner"] = new JsonObject { ["user"] = "tester" },
                        ["perm"] = new JsonObject { ["read"] = true, ["write"] = CanWrite, ["delete"] = true } } }) };
            else if (method == "list")
            {
                if (EditCount > 0 && FailReadAfterEdit) throw new HttpRequestException();
                data = new() { ["offset"] = 0, ["total"] = HasLink ? 1 : 0,
                    ["links"] = HasLink ? new JsonArray(Link.DeepClone()) : new JsonArray() };
            }
            else if (method is "edit" or "create")
            {
                if (method == "edit") EditCount++;
                else { Link["id"] = "new"; Link["url"] = "https://share.invalid/new"; HasLink = true; }
                foreach (var key in new[] { "date_available", "date_expired", "request_name", "request_info", "protect_type" })
                    if (values.ContainsKey(key)) Link[key] = Scalar(key);
                if (values.ContainsKey("protect_type")) Link["has_password"] = Scalar("protect_type") == "password";
                if (values.ContainsKey("password"))
                { Link["has_password"] = Scalar("password").Length > 0; Link["protect_type"] = Scalar("password").Length > 0 ? "password" : "none"; }
                foreach (var key in new[] { "protect_users", "protect_groups", "expire_times" })
                    if (values.ContainsKey(key)) Link[key] = JsonNode.Parse(values[key]);
                if (values.ContainsKey("file_request")) { Link["enable_upload"] = true; Link["project_name"] = "SYNO.SDS.App.SharingUpload.Application"; }
                if (method == "edit" && LoseEditReceipt) throw new HttpRequestException();
                data = method == "create" && !OmitCreateId ? new() { ["id"] = "new" } : new();
            }
            else throw new InvalidOperationException("Unexpected synthetic request.");
            return new(HttpStatusCode.OK) { Content = new StringContent(new JsonObject { ["success"] = true, ["data"] = data }.ToJsonString(), Encoding.UTF8, "application/json") };
        }
    }
}
