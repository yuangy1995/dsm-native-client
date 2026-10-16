using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Files.CopyMove;

public sealed partial class CrossNasTransferFlowTests
{
    [Theory]
    [InlineData(0)]
    [InlineData(23)]
    [InlineData(4 * 1024 * 1024 + 13)]
    public async Task CopiesExactContentUsingIndependentSessionsAndSingleUpload(int length)
    {
        using var pair = new Pair(length);
        var result = await pair.Copy();
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Result.Status);
        Assert.Equal(1, result.Result.Counts.Succeeded);
        Assert.Equal(pair.SourceApi.Files["/share/item.bin"].Bytes, pair.TargetApi.Files["/backup/item.bin"].Bytes);
        Assert.Equal(1, pair.TargetApi.Uploads); Assert.Equal(1, pair.TargetApi.Permissions);
        Assert.All(result.Items, item => Assert.Equal(CrossNasTransferItemState.Copied, item.State));
        if (length > 4 * 1024 * 1024)
            Assert.Contains(pair.SourceApi.Ranges, range => range.Offset > 0 && range.Version == "\"v1\"");
        var duplicate = await pair.Source.CrossNasCopyMoveAsync(pair.Request);
        Assert.Equal(result.OperationId, duplicate.OperationId); Assert.Equal(1, pair.TargetApi.Uploads);
    }

    [Fact]
    public async Task SameSizeWrongContentRemainsUnknownUntilReadOnlyRecovery()
    {
        using var pair = new Pair(23); pair.TargetApi.Corrupt = true;
        var first = await pair.Copy();
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, first.Result.Status);
        Assert.Equal(CrossNasTransferItemState.ResultUnavailable, Assert.Single(first.Items).State);
        var duplicate = await pair.Source.CrossNasCopyMoveAsync(pair.Request with { OperationId = Guid.NewGuid() });
        Assert.Equal(first.OperationId, duplicate.OperationId); Assert.Equal(1, pair.TargetApi.Uploads);
        pair.TargetApi.Corrupt = false;
        var recovered = await pair.Source.ReviewCrossNasTransferAsync(first.OperationId);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, recovered!.Result.Status); Assert.Equal(1, pair.TargetApi.Uploads);
    }

    [Fact]
    public async Task LostReceiptCannotClaimMatchingContentOrReplayAfterReopen()
    {
        using var pair = new Pair(23); pair.TargetApi.UploadStatus = FileUploadTransportStatus.SubmittedButUnverified;
        var first = await pair.Copy();
        var reopened = pair.SourceApi.Repository();
        var history = Assert.Single(await reopened.GetCrossNasTransfersAsync());
        var refreshed = await reopened.ReviewCrossNasTransferAsync(history.Id);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, first.Result.Status);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, refreshed!.Result.Status);
        Assert.Empty(pair.TargetApi.Ranges); Assert.Equal(1, pair.TargetApi.Uploads);
        await reopened.ContinueCrossNasTransferAsync(history.Id);
        Assert.Equal(1, pair.TargetApi.Uploads);
    }

    [Fact]
    public async Task ReadOnlyRecoveryCanUseRebuiltSameAccountTargetButRejectsChangedAccount()
    {
        using var pair = new Pair(23); pair.TargetApi.Corrupt = true;
        var first = await pair.Copy();
        var changed = new Api(pair.TargetApi.Profile with { Username = "another" });
        changed.Files = pair.TargetApi.Files;
        DsmRepository.RegisterRepository(changed.Profile.Id, changed.Repository());
        var rejected = await pair.Source.ReviewCrossNasTransferAsync(first.OperationId);
        Assert.Equal(MutationErrorCategory.Authentication, rejected!.Result.ErrorCategory); Assert.Empty(changed.Ranges);
        var rebuilt = new Api(pair.TargetApi.Profile) { Files = pair.TargetApi.Files };
        DsmRepository.RegisterRepository(rebuilt.Profile.Id, rebuilt.Repository());
        var recovered = await pair.Source.ReviewCrossNasTransferAsync(first.OperationId);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, recovered!.Result.Status);
        Assert.Equal(0, rebuilt.Uploads); Assert.Equal(1, pair.TargetApi.Uploads);
    }

    [Theory]
    [InlineData(23)]
    [InlineData(20 * 1024 * 1024)]
    public async Task PermissionDenialWakesProducerWithoutWriting(int length)
    {
        using var pair = new Pair(length); pair.TargetApi.Deny = true;
        var result = await pair.Copy();
        Assert.Equal(MutationResultStatus.ConfirmedFailure, result.Result.Status);
        Assert.False(result.Result.Submitted); Assert.Equal(0, pair.TargetApi.Uploads);
        Assert.Equal(MutationErrorCategory.Permission, result.Result.ErrorCategory);
    }

    [Fact]
    public async Task ExistingTargetIsNeverOverwritten()
    {
        using var pair = new Pair(23); pair.TargetApi.Add("/backup/item.bin", [99]);
        var result = await pair.Copy();
        Assert.False(result.Result.Submitted); Assert.Equal(0, pair.TargetApi.Uploads);
        Assert.Equal(new byte[] { 99 }, pair.TargetApi.Files["/backup/item.bin"].Bytes);
    }

    [Theory]
    [InlineData("range")]
    [InlineData("link")]
    [InlineData("size")]
    [InlineData("name")]
    [InlineData("owner")]
    public async Task InvalidSourceOrTargetIdentityStopsBeforeSubmission(string kind)
    {
        using var pair = new Pair(23);
        if (kind == "range") pair.SourceApi.BadRange = true;
        if (kind == "link") pair.SourceApi.Files["/share/item.bin"].Type = "symlink";
        if (kind == "size") pair.Request = pair.Request with { FileSize = 24 };
        if (kind == "name") pair.Request = pair.Request with { SourceName = "different.bin" };
        if (kind == "owner") pair.Request = pair.Request with { TargetIdentity = "changed-identity" };
        var result = await pair.Copy();
        Assert.False(result.Result.Submitted); Assert.Equal(0, pair.TargetApi.Uploads); Assert.Equal(0, pair.TargetApi.Creates);
    }

    [Fact]
    public async Task SourceVersionChangeStopsUnknownUploadWithoutRetry()
    {
        using var pair = new Pair(4 * 1024 * 1024 + 23); pair.SourceApi.ChangeVersion = true;
        pair.SourceApi.BeforeLaterRange = pair.TargetApi.UploadStarted.Task;
        var first = await pair.Copy();
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, first.Result.Status);
        await pair.Source.ReviewCrossNasTransferAsync(first.OperationId);
        await pair.Source.CrossNasCopyMoveAsync(pair.Request);
        Assert.Equal(1, pair.TargetApi.Uploads);
    }

    [Fact]
    public async Task FolderPreservesEmptyDirectoriesAndEveryItemResult()
    {
        using var pair = new Pair(3); pair.Folder();
        var result = await pair.Copy();
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Result.Status);
        Assert.Equal(4, result.Items.Count); Assert.Equal(4, result.Result.Counts.Succeeded);
        Assert.Equal(2, pair.TargetApi.Creates); Assert.Equal(2, pair.TargetApi.Uploads);
        Assert.True(pair.TargetApi.Files["/backup/folder/empty"].Directory);
    }

    [Fact]
    public async Task UnknownFileStopsRemainingItemsAndRefreshNeverStartsThem()
    {
        using var pair = new Pair(3); pair.Folder(); pair.TargetApi.Corrupt = true;
        var first = await pair.Copy();
        Assert.Equal(2, first.Result.Counts.Succeeded);
        Assert.Equal(1, first.Result.Counts.Unknown);
        Assert.Equal(1, first.Items.Count(item => item.State == CrossNasTransferItemState.NotStarted));
        Assert.Equal(1, pair.TargetApi.Uploads);
        pair.TargetApi.Corrupt = false;
        var reviewed = await pair.Source.ReviewCrossNasTransferAsync(first.OperationId);
        Assert.True(reviewed!.CanContinue); Assert.Equal(1, pair.TargetApi.Uploads);
        var completed = await pair.Source.ContinueCrossNasTransferAsync(first.OperationId);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, completed!.Result.Status);
        Assert.Equal(2, pair.TargetApi.Uploads); Assert.Equal(2, pair.TargetApi.Creates);
    }

    [Fact]
    public async Task CancellationBetweenItemsKeepsCompletedFolderAndRequiresExplicitContinue()
    {
        using var pair = new Pair(3); pair.Folder();
        using var cancel = new CancellationTokenSource(); pair.TargetApi.OnCreate = cancel.Cancel;
        var first = await pair.Copy(cancel.Token);
        Assert.Equal(MutationResultStatus.ConfirmedFailure, first.Result.Status);
        Assert.Equal(0, first.Result.Counts.Failed); Assert.Equal(0, first.Result.Counts.Unknown);
        Assert.Equal(1, first.Result.Counts.Succeeded); Assert.True(first.CanContinue); Assert.Equal(0, pair.TargetApi.Uploads);
        pair.TargetApi.OnCreate = null;
        var completed = await pair.Source.ContinueCrossNasTransferAsync(first.OperationId);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, completed!.Result.Status);
        Assert.Equal(2, pair.TargetApi.Creates); Assert.Equal(2, pair.TargetApi.Uploads);
    }

    [Fact]
    public async Task UnknownFolderDoesNotClaimSameNameOrStartChildren()
    {
        using var pair = new Pair(3); pair.Folder(); pair.TargetApi.FolderStatus = FileMutationTransportStatus.SubmittedButUnverified;
        var first = await pair.Copy();
        var reviewed = await pair.Source.ReviewCrossNasTransferAsync(first.OperationId);
        await pair.Source.ContinueCrossNasTransferAsync(first.OperationId);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, reviewed!.Result.Status);
        Assert.False(reviewed.CanContinue); Assert.Equal(1, pair.TargetApi.Creates); Assert.Equal(0, pair.TargetApi.Uploads);
    }

    [Fact]
    public async Task IncompleteSourcePageCannotCreateTargetRoot()
    {
        using var pair = new Pair(3); pair.Folder(); pair.SourceApi.InvalidPage = true;
        var result = await pair.Copy();
        Assert.False(result.Result.Submitted); Assert.Equal(0, pair.TargetApi.Creates); Assert.Equal(0, pair.TargetApi.Uploads);
    }

    [Fact]
    public async Task AcceptedFolderWithReadFailureRecoversWithoutCreatingItAgain()
    {
        using var pair = new Pair(3); pair.Folder(); pair.TargetApi.FailListAfterCreate = true;
        var first = await pair.Copy();
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, first.Result.Status); Assert.Equal(1, pair.TargetApi.Creates);
        pair.TargetApi.FailListAfterCreate = false;
        var recovered = await pair.Source.ReviewCrossNasTransferAsync(first.OperationId);
        Assert.True(recovered!.CanContinue); Assert.Equal(0, pair.TargetApi.Uploads);
        var complete = await pair.Source.ContinueCrossNasTransferAsync(first.OperationId);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, complete!.Result.Status); Assert.Equal(2, pair.TargetApi.Creates);
    }

    [Fact]
    public async Task FullSourcePaginationRejectsUnsafeLastItemBeforeAnyWrite()
    {
        using var pair = new Pair(3); pair.Folder();
        pair.SourceApi.Files.Clear(); pair.SourceApi.Add("/share/folder", [], true);
        for (var index = 0; index < 501; index++) pair.SourceApi.Add($"/share/folder/file-{index:D3}", []);
        pair.SourceApi.Files["/share/folder/file-500"].Type = "symlink";
        var result = await pair.Copy();
        Assert.False(result.Result.Submitted); Assert.Equal(new[] { 0, 500 }, pair.SourceApi.PageOffsets);
        Assert.Equal(0, pair.TargetApi.Creates); Assert.Equal(0, pair.TargetApi.Uploads);
    }

    [Theory]
    [InlineData("normal", true)]
    [InlineData("shared_folder", true)]
    [InlineData("remote", false)]
    public async Task DestinationMetadataUsesRecordedMountSemantics(string mount, bool accepted)
    {
        using var pair = new Pair(3); pair.TargetApi.Files["/backup"].Mount = mount;
        var result = await pair.Copy();
        Assert.Equal(accepted ? MutationResultStatus.ConfirmedSuccess : MutationResultStatus.ConfirmedFailure, result.Result.Status);
        Assert.Equal(accepted ? 1 : 0, pair.TargetApi.Uploads);
    }

    [Fact]
    public async Task ConcurrentDuplicateKeepsOneSubmissionAndDifferentAccountCannotReadHistory()
    {
        using var pair = new Pair(23); pair.TargetApi.HoldUpload = new(TaskCreationOptions.RunContinuationsAsynchronously);
        var first = pair.Copy(); await pair.TargetApi.UploadStarted.Task.WaitAsync(TimeSpan.FromSeconds(5));
        var duplicate = await pair.Source.CrossNasCopyMoveAsync(pair.Request);
        Assert.Equal(pair.Request.OperationId, duplicate.OperationId); Assert.True(duplicate.IsRunning); Assert.Equal(1, pair.TargetApi.Uploads);
        pair.TargetApi.HoldUpload.SetResult(); await first;
        var other = new DsmRepository(pair.SourceApi.Profile with { Username = "another" }, pair.SourceApi.Session, pair.SourceApi, Api.Capabilities);
        Assert.Empty(await other.GetCrossNasTransfersAsync()); Assert.Null(await other.ReviewCrossNasTransferAsync(duplicate.OperationId));
    }

    private sealed class Pair : IDisposable
    {
        public Api SourceApi { get; } = new(new(Guid.NewGuid(), "Source", "source.invalid", 5001, "reader"));
        public Api TargetApi { get; } = new(new(Guid.NewGuid(), "Target", "target.invalid", 5001, "writer"));
        public DsmRepository Source { get; }
        public CrossNasCopyMoveRequest Request;
        public Pair(int length, IProtectedTaskStore? store = null)
        {
            SourceApi.Add("/share/item.bin", Enumerable.Range(0, length).Select(i => (byte)(i % 251)).ToArray());
            TargetApi.Add("/backup", [], true);
            Source = SourceApi.Repository(store); DsmRepository.RegisterRepository(TargetApi.Profile.Id, TargetApi.Repository(store));
            Request = new(SourceApi.Profile.Id, TargetApi.Profile.Id, "/share/item.bin", "item.bin", false, length, "/backup", false,
                OperationId: Guid.NewGuid());
        }
        public void Folder()
        {
            SourceApi.Files.Clear(); SourceApi.Add("/share/folder", [], true); SourceApi.Add("/share/folder/empty", [], true);
            SourceApi.Add("/share/folder/a.bin", [1, 2, 3]); SourceApi.Add("/share/folder/b.bin", [4, 5, 6]);
            Request = Request with { SourcePath = "/share/folder", SourceName = "folder", IsDirectory = true, FileSize = 0 };
        }
        public Task<CrossNasCopyMoveOutcome> Copy(CancellationToken token = default) =>
            Source.CrossNasCopyMoveAsync(Request, cancellationToken: token).WaitAsync(TimeSpan.FromSeconds(15));
        public void Dispose() => DsmRepository.UnregisterRepository(TargetApi.Profile.Id);
    }

    private sealed class Entry(byte[] bytes, bool directory)
    {
        public byte[] Bytes { get; } = bytes;
        public bool Directory { get; } = directory;
        public string? Type { get; set; }
        public string? Mount { get; set; }
        public bool CanDelete { get; set; } = true;
    }
    private sealed class Api(NasProfile profile) : IDsmApiClient
    {
        public static IReadOnlyDictionary<string, ApiCapability> Capabilities { get; } = new[]
        {
            new ApiCapability("SYNO.FileStation.List", "entry.cgi", 1, 2, "FORM"),
            new ApiCapability("SYNO.FileStation.Download", "entry.cgi", 1, 2, "FORM"),
            new ApiCapability("SYNO.FileStation.Upload", "entry.cgi", 1, 2, "MULTIPART"),
            new ApiCapability("SYNO.FileStation.CreateFolder", "entry.cgi", 1, 2, "FORM"),
            new ApiCapability("SYNO.FileStation.CheckPermission", "entry.cgi", 1, 3, "FORM"),
            new ApiCapability("SYNO.FileStation.Delete", "entry.cgi", 1, 2, "FORM"),
            new ApiCapability("SYNO.FileStation.CopyMove", "entry.cgi", 1, 3, "FORM"),
            new ApiCapability("SYNO.FileStation.Rename", "entry.cgi", 1, 2, "FORM"),
        }.ToDictionary(item => item.Name);
        public NasProfile Profile { get; } = profile;
        public DsmSession Session { get; } = new(profile.Id, "synthetic-session-" + profile.Id, null, null);
        public Dictionary<string, Entry> Files { get; set; } = [];
        public int Uploads, Creates, Permissions;
        public List<string> Deletes { get; } = [];
        public int DeleteReads;
        public Action? OnDelete;
        public bool ThrowDeleteRead, RemoveOnDelete = true;
        public FileMutationTransportStatus DeleteStatus = FileMutationTransportStatus.ResponseReceived;
        public FileRecycleTaskTransportStatus DeleteTaskStatus = FileRecycleTaskTransportStatus.Finished;
        public TaskCompletionSource? HoldDelete;
        public TaskCompletionSource DeleteStarted { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public bool Corrupt, Deny, BadRange, ChangeVersion, InvalidPage, FailListAfterCreate;
        public Action? OnCreate;
        public FileUploadTransportStatus UploadStatus = FileUploadTransportStatus.Accepted;
        public FileMutationTransportStatus FolderStatus = FileMutationTransportStatus.ResponseReceived;
        public TaskCompletionSource? HoldUpload;
        public Task? BeforeLaterRange;
        public TaskCompletionSource UploadStarted { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public List<(long Offset, string? Version)> Ranges { get; } = [];
        public List<int> PageOffsets { get; } = [];
        public DsmRepository Repository(IProtectedTaskStore? store = null) => new(Profile, Session, this, Capabilities, store);
        public void Add(string path, byte[] content, bool directory = false) => Files.Add(path, new(content, directory));
        private void Check(NasProfile profile, DsmSession session) { Assert.Equal(Profile.Id, profile.Id); Assert.Equal(Session, session); }
        public Uri GetBaseUri(NasProfile profile) => new("https://" + profile.Host);
        public Task<JsonObject> CallAsync(NasProfile profile, DsmSession session, ApiCapability capability, string method,
            IReadOnlyDictionary<string, string>? parameters = null, CancellationToken cancellationToken = default)
        {
            Check(profile, session); cancellationToken.ThrowIfCancellationRequested(); Assert.Equal("SYNO.FileStation.List", capability.Name);
            if (method == "getinfo")
            {
                var path = JsonSerializer.Deserialize<string[]>(parameters!["path"])!.Single();
                return Task.FromResult(new JsonObject { ["files"] = new JsonArray(Files.TryGetValue(path, out var item) ? Row(path, item) :
                    new JsonObject { ["path"] = path, ["code"] = 408L }) });
            }
            Assert.Equal("list", method);
            if (FailListAfterCreate && Creates > 0) throw new InvalidDataException("合成创建后读取失败。");
            var parent = parameters!["folder_path"]; var offset = int.Parse(parameters["offset"]); var limit = int.Parse(parameters["limit"]);
            PageOffsets.Add(offset);
            var children = Files.Where(pair => pair.Key[..pair.Key.LastIndexOf('/')] == parent).OrderBy(pair => pair.Key, StringComparer.Ordinal).ToArray();
            return Task.FromResult(new JsonObject { ["offset"] = offset, ["total"] = InvalidPage ? children.Length + 1 : children.Length,
                ["files"] = new JsonArray(children.Skip(offset).Take(limit).Select(pair => (JsonNode)Row(pair.Key, pair.Value)).ToArray()) });
        }
        public Task<JsonObject> CallReadJsonObjectAsync(NasProfile profile, DsmSession session, ApiCapability capability, int requiredVersion,
            string method, IReadOnlyDictionary<string, string>? parameters = null, CancellationToken cancellationToken = default) =>
            CallAsync(profile, session, capability, method, parameters, cancellationToken);
        public async Task<FileUploadTransportResult> UploadFileAsync(NasProfile profile, DsmSession session, ApiCapability capability,
            FileUploadRequest request, IProgress<long>? progress = null, CancellationToken cancellationToken = default)
        {
            Check(profile, session); Uploads++; UploadStarted.TrySetResult();
            if (HoldUpload is not null) await HoldUpload.Task.WaitAsync(cancellationToken);
            var bytes = new byte[checked((int)request.Length)]; await request.Content.ReadExactlyAsync(bytes, cancellationToken);
            Assert.False(request.Overwrite); Add(request.FolderPath + "/" + request.FileName, bytes); progress?.Report(bytes.Length);
            return new(UploadStatus);
        }
        public Task<FilePermissionTransportResult> CheckFileMutationPermissionAsync(NasProfile profile, DsmSession session, ApiCapability capability,
            string parentPath, string name, CancellationToken cancellationToken = default)
        { Check(profile, session); Permissions++; return Task.FromResult(new FilePermissionTransportResult(Deny ? FilePermissionTransportStatus.Denied : FilePermissionTransportStatus.Allowed, Deny ? MutationErrorCategory.Permission : null)); }
        public Task<FileMutationTransportResult> CreateFolderMutationAsync(NasProfile profile, DsmSession session, ApiCapability capability,
            string parentPath, string name, CancellationToken cancellationToken = default)
        { Check(profile, session); Creates++; Add(parentPath + "/" + name, [], true); OnCreate?.Invoke(); return Task.FromResult(new FileMutationTransportResult(FolderStatus)); }
        public async Task<FileRecycleStartTransportResult> StartNonRecursiveFileDeleteAsync(NasProfile profile, DsmSession session,
            ApiCapability capability, string sourcePath, CancellationToken cancellationToken = default)
        {
            Check(profile, session); cancellationToken.ThrowIfCancellationRequested();
            Assert.DoesNotContain(Files.Keys, path => path.StartsWith(sourcePath + "/", StringComparison.Ordinal));
            Deletes.Add(sourcePath); DeleteStarted.TrySetResult();
            if (HoldDelete is not null) await HoldDelete.Task.WaitAsync(cancellationToken);
            if (RemoveOnDelete && DeleteStatus != FileMutationTransportStatus.ConfirmedFailure) Files.Remove(sourcePath);
            OnDelete?.Invoke();
            return new(DeleteStatus, DeleteStatus == FileMutationTransportStatus.ResponseReceived ? "delete-" + Deletes.Count : null);
        }
        public Task<FileRecycleTaskTransportResult> ReadFileRecycleStatusAsync(NasProfile profile, DsmSession session,
            ApiCapability capability, string taskId, CancellationToken cancellationToken = default)
        {
            Check(profile, session); cancellationToken.ThrowIfCancellationRequested(); DeleteReads++;
            Assert.StartsWith("delete-", taskId);
            if (ThrowDeleteRead) throw new IOException("合成删除查询断网。");
            return Task.FromResult(new FileRecycleTaskTransportResult(DeleteTaskStatus));
        }
        public async Task<FileRangeReadResult> ReadFileRangeResultAsync(NasProfile profile, DsmSession session, ApiCapability capability,
            string remotePath, long offset, long length, string? expectedContentVersion = null, long? expectedTotalLength = null, CancellationToken cancellationToken = default)
        {
            Check(profile, session); cancellationToken.ThrowIfCancellationRequested(); Ranges.Add((offset, expectedContentVersion));
            if (offset > 0 && BeforeLaterRange is not null) await BeforeLaterRange.WaitAsync(TimeSpan.FromSeconds(5), cancellationToken);
            var bytes = Files[remotePath].Bytes.AsSpan((int)offset, (int)length).ToArray();
            if (Corrupt && bytes.Length > 0) bytes[0] ^= 1;
            return new FileRangeReadResult(206, offset, length, BadRange ? offset + 1 : offset, length,
                Files[remotePath].Bytes.Length, length, bytes, ChangeVersion && offset > 0 ? "\"v2\"" : "\"v1\"", true);
        }
        private static JsonObject Row(string path, Entry item) => new()
        {
            ["path"] = path, ["name"] = path[(path.LastIndexOf('/') + 1)..], ["isdir"] = item.Directory, ["size"] = (long)item.Bytes.Length,
            ["additional"] = new JsonObject { ["size"] = (long)item.Bytes.Length, ["time"] = new JsonObject { ["mtime"] = 10L },
                ["perm"] = new JsonObject { ["write"] = true, ["delete"] = item.CanDelete }, ["type"] = item.Type, ["mount_point_type"] = item.Mount },
        };
        public Task<IReadOnlyDictionary<string, ApiCapability>> DiscoverAsync(NasProfile profile, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<DsmSession> LoginAsync(NasProfile profile, string password, string? otp, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task LogoutAsync(NasProfile profile, DsmSession session, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<byte[]> ReadFileRangeAsync(NasProfile profile, DsmSession session, ApiCapability capability, string remotePath, long offset, long length, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    }
}
