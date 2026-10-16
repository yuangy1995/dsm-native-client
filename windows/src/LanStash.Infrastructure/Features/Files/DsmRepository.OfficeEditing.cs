using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    // 公开 Upload 不提供原子版本条件覆盖；专用测试包完成真实并发验收后才能开放。
    public bool OfficeAutomaticUploadEnabled { get; init; }
    public string OfficeOwnerId => ServiceScope();
    public bool HasOfficeSessionWithin(string path) => OfficeEditingConflicts([path]);
    public OfficeEditingAvailability OfficeAvailability => new(
        FileContentCapability("SYNO.FileStation.Download", 2) && FileContentCapability("SYNO.FileStation.List", 2) && FileMD5CapabilityAvailable,
        OfficeAutomaticUploadEnabled && FileContentUploadAvailable && FileMD5CapabilityAvailable && OfficeRecoveryAvailable,
        OfficeRecoveryAvailable);

    public async Task<IReadOnlyList<OfficeEditingSessionInfo>> GetOfficeSessionsAsync(CancellationToken token = default)
    {
        await InitializeOfficeRecoveryAsync().ConfigureAwait(false);
        token.ThrowIfCancellationRequested();
        if (!OfficeRecoveryAvailable) throw new IOException("office.recovery-unavailable");
        lock (OfficeRecords.Entries)
            return OfficeRecords.Entries.Values.Where(entry => !entry.Creating).Select(entry => entry.Info)
                .Where(info => info.OwnerId == OfficeOwnerId && info.ProfileId == ProfileId).ToArray();
    }

    public async Task<OfficeRemoteSnapshot> ReadOfficeRemoteAsync(string path, CancellationToken token = default)
    {
        if (!OfficeAvailability.CanRead || !ValidMutationObjectPath(path) || ArchiveContainsRecycleSegment(path))
            throw new NotSupportedException("office.read-unavailable");
        var before = await ReadFileMetadataAsync(path, token).ConfigureAwait(false);
        if (before?.Item is not { IsDirectory: false, ModifiedAt: not null } item ||
            !OfficeDocumentFormat.Supports(item) || UploadIsLink(before)) throw new IOException("office.target-changed");
        var md5 = await CalculateMD5Async(path, token).ConfigureAwait(false);
        if (!SameOfficeMetadata(before, await ReadFileMetadataAsync(path, token).ConfigureAwait(false)))
            throw new IOException("office.target-changed");
        return new(before, md5);
    }

    public async Task<OfficeEditingSessionInfo> CreateOfficeSessionAsync(Guid id, string localPath,
        OfficeRemoteSnapshot baseline, OfficeContentFingerprint fingerprint, CancellationToken token = default)
    {
        await InitializeOfficeRecoveryAsync().ConfigureAwait(false);
        if (!OfficeAvailability.CanAutoSave) throw new NotSupportedException("office.edit-unavailable");
        if (id == Guid.Empty || !ValidOfficeBaseline(baseline, fingerprint) ||
            !ValidOfficeLocalPath(localPath, baseline.Metadata.Item.Name)) throw new ArgumentException("office.invalid-session");
        await OfficeRecords.CreateGate.WaitAsync(token).ConfigureAwait(false);
        var path = baseline.Metadata.Item.Path;
        var marker = new FileMutationReview("officeEditing", MutationParent(path), path, null, false, [path]);
        var reserved = false;
        OfficeEntry? entry = null;
        var checkpointStarted = false;
        try
        {
            lock (OfficeRecords.Entries)
                if (OfficeRecords.Entries.ContainsKey(id) || OfficeRecords.Entries.Values.Any(entry =>
                    entry.Info.State != OfficeEditingState.Stopped && (entry.Info.ProfileId == ProfileId && entry.Info.RemotePath == path ||
                    string.Equals(entry.Info.LocalPath, localPath, StringComparison.OrdinalIgnoreCase))))
                    throw new InvalidOperationException("office.session-exists");
            // 与移动、回收和归档沿同一锁序登记；不能在预检窗口中让另一执行者接管目标。
            lock (FileMutationState().Sync)
            {
                var reservation = ReserveFileMutation(marker);
                reserved = reservation.Acquired;
                if (!reserved || reservation.PendingReview is not null) throw new InvalidOperationException("office.target-busy");
                var moves = FileCopyMoveState(); var recycle = FileRecycleState(); var archive = ArchiveMutationStateForProfile(ProfileId);
                lock (moves.Sync)
                lock (recycle.Sync)
                lock (archive.Sync)
                {
                    var busy = moves.ActiveTargets.Concat(moves.Reviews.Values.SelectMany(review => review.Targets))
                        .Concat(recycle.ActiveTargets).Concat(recycle.Reviews.Values.SelectMany(review => review.Targets))
                        .Concat(archive.ActivePaths).Concat(archive.Reviews.Values.SelectMany(review => review.ReservedPaths))
                        .Concat(archive.ExtractionReviews.Values.SelectMany(review => review.ReservedPaths));
                    if (busy.Any(value => CrossNasPathsOverlap(value, path))) throw new InvalidOperationException("office.target-busy");
                    entry = new(new(id, ProfileId, OfficeOwnerId, Path.GetFullPath(localPath), baseline, fingerprint, OfficeEditingState.Ready))
                        { Creating = true };
                    _ = entry.Gate.Wait(0);
                    lock (OfficeRecords.Entries) OfficeRecords.Entries.Add(id, entry);
                }
            }
            if (!await OfficeBaselineMatchesAsync(baseline, token).ConfigureAwait(false)) throw new IOException("office.target-changed");
            var permission = await OfficePermissionAsync(path, token).ConfigureAwait(false);
            if (permission is not null) throw new UnauthorizedAccessException("office.write-denied");
            token.ThrowIfCancellationRequested();
            // 先登记，持久化失败也禁止另一个执行者覆盖该目标。
            checkpointStarted = true;
            await SaveOfficeRecordAsync(entry).ConfigureAwait(false);
            return entry.Info;
        }
        catch
        {
            if (entry is not null && !checkpointStarted) lock (OfficeRecords.Entries) OfficeRecords.Entries.Remove(id);
            throw;
        }
        finally
        {
            if (entry is not null) { entry.Creating = false; entry.Gate.Release(); }
            if (reserved) ReleaseFileMutation(marker.Targets); OfficeRecords.CreateGate.Release();
        }
    }

    public async Task<OfficeEditingSessionInfo> SaveOfficeSessionAsync(Guid id, Stream content,
        OfficeContentFingerprint fingerprint, CancellationToken token = default)
    {
        ArgumentNullException.ThrowIfNull(content);
        if (!ValidOfficeFingerprint(fingerprint) || !content.CanRead) throw new ArgumentException("office.invalid-content");
        var entry = OfficeEntryFor(id);
        if (!await entry.Gate.WaitAsync(0, token).ConfigureAwait(false)) return entry.Info;
        var previousExecuting = OfficeExecuting.Value;
        OfficeExecuting.Value = id;
        try
        {
            if (!OfficeAvailability.CanAutoSave || entry.StopRequested || entry.Info.State is not
                (OfficeEditingState.Ready or OfficeEditingState.Saved)) return entry.Info;
            if (string.Equals(fingerprint.Sha256, entry.Info.Fingerprint.Sha256, StringComparison.OrdinalIgnoreCase)) return entry.Info;
            var path = entry.Info.RemotePath;
            var operation = Guid.NewGuid();
            var request = new FileUploadRequest(content, fingerprint.Length, MutationParent(path),
                entry.Info.Baseline.Metadata.Item.Name, true, operation);
            var result = await UploadFileCoreAsync(request, null, token, async pending =>
            {
                entry.AttemptId = operation; entry.Attempt = fingerprint; entry.Upload = pending;
                entry.Info = entry.Info with { State = OfficeEditingState.ResultUnavailable, Error = null };
                await SaveOfficeRecordAsync(entry).ConfigureAwait(false);
            }, async cancellation =>
            {
                if (entry.StopRequested) return UploadCancelled();
                return await OfficeBaselineMatchesAsync(entry.Info.Baseline, cancellation).ConfigureAwait(false) ? null :
                    UploadFailure(MutationErrorCategory.Conflict, "office.target-changed");
            }).ConfigureAwait(false);
            if (result.Status == MutationResultStatus.ConfirmedSuccess)
                return await CompleteOfficeSaveAsync(entry, CancellationToken.None).ConfigureAwait(false);
            if (result.Status is MutationResultStatus.SubmittedButUnverified or MutationResultStatus.CancellationRequestedAfterSubmission)
                entry.Info = entry.Info with { State = OfficeEditingState.ResultUnavailable, Error = result.ErrorCategory };
            else
            {
                ClearOfficeAttempt(entry);
                entry.Info = entry.Info with { State = entry.StopRequested ? OfficeEditingState.Stopped :
                    result.ErrorCategory == MutationErrorCategory.Conflict ? OfficeEditingState.Conflict : OfficeEditingState.Paused,
                    Error = result.ErrorCategory, StopRequested = entry.StopRequested };
            }
            await SaveOfficeRecordAsync(entry).ConfigureAwait(false);
            return entry.Info;
        }
        finally { OfficeExecuting.Value = previousExecuting; entry.Gate.Release(); }
    }

    public async Task<OfficeEditingSessionInfo> ReviewOfficeSessionAsync(Guid id, CancellationToken token = default)
    {
        await InitializeOfficeRecoveryAsync().ConfigureAwait(false);
        var entry = OfficeEntryFor(id);
        if (!await entry.Gate.WaitAsync(0, token).ConfigureAwait(false)) return entry.Info;
        try
        {
            if (entry.Info.State != OfficeEditingState.ResultUnavailable || entry.Attempt is null || entry.AttemptId is null) return entry.Info;
            var path = entry.Info.RemotePath;
            var upload = entry.Upload ??= new(entry.AttemptId.Value, entry.Attempt.Length,
                new("uploadFile", MutationParent(path), path, null, false, [path]), new())
                { Submitted = true, Accepted = entry.Accepted, Hash = entry.UploadHash };
            var result = await ReviewFileUploadCoreAsync((OfficeOwnerId, path), upload, token, validateCompleted: true).ConfigureAwait(false);
            if (result.Status == MutationResultStatus.ConfirmedSuccess)
                return await CompleteOfficeSaveAsync(entry, token).ConfigureAwait(false);
            return entry.Info;
        }
        finally { entry.Gate.Release(); }
    }

    private async Task<OfficeEditingSessionInfo> CompleteOfficeSaveAsync(OfficeEntry entry, CancellationToken token)
    {
        try
        {
            var current = await ReadOfficeRemoteAsync(entry.Info.RemotePath, token).ConfigureAwait(false);
            if (entry.Attempt is not { } fingerprint || !ValidOfficeBaseline(current, fingerprint)) return entry.Info;
            entry.Info = entry.Info with { Baseline = current, Fingerprint = fingerprint, Error = null,
                State = entry.StopRequested ? OfficeEditingState.Stopped : OfficeEditingState.Saved,
                StopRequested = entry.StopRequested, SavedAt = DateTimeOffset.UtcNow };
            ClearOfficeAttempt(entry);
            await SaveOfficeRecordAsync(entry).ConfigureAwait(false);
        }
        catch when (OfficeRecoveryAvailable)
        {
            // 远端校验失败仍保留原上传事实；存储失败必须继续抛出并关闭写入口。
        }
        return entry.Info;
    }

    public async Task<OfficeEditingSessionInfo> ResumeOfficeSessionAsync(Guid id, CancellationToken token = default)
    {
        var entry = OfficeEntryFor(id);
        await entry.Gate.WaitAsync(token).ConfigureAwait(false);
        try
        {
            if (!OfficeAvailability.CanAutoSave || entry.Info.State is OfficeEditingState.ResultUnavailable or OfficeEditingState.Stopped)
                return entry.Info;
            if (!await OfficeBaselineMatchesAsync(entry.Info.Baseline, token).ConfigureAwait(false))
                entry.Info = entry.Info with { State = OfficeEditingState.Conflict, Error = MutationErrorCategory.Conflict };
            else if (await OfficePermissionAsync(entry.Info.RemotePath, token).ConfigureAwait(false) is { } error)
                entry.Info = entry.Info with { State = OfficeEditingState.Paused, Error = error };
            else
            {
                entry.StopRequested = false;
                entry.Info = entry.Info with { State = OfficeEditingState.Ready, StopRequested = false, Error = null };
            }
            await SaveOfficeRecordAsync(entry).ConfigureAwait(false);
            return entry.Info;
        }
        finally { entry.Gate.Release(); }
    }

    public async Task<OfficeEditingSessionInfo> StopOfficeSessionAsync(Guid id, CancellationToken token = default)
    {
        var entry = OfficeEntryFor(id);
        entry.StopRequested = true;
        await entry.Gate.WaitAsync(token).ConfigureAwait(false);
        try
        {
            entry.Info = entry.Info with { StopRequested = true, State = entry.Info.State == OfficeEditingState.ResultUnavailable
                ? OfficeEditingState.ResultUnavailable : OfficeEditingState.Stopped };
            await SaveOfficeRecordAsync(entry).ConfigureAwait(false);
            return entry.Info;
        }
        finally { entry.Gate.Release(); }
    }

    private static void ClearOfficeAttempt(OfficeEntry entry)
    { entry.Attempt = null; entry.AttemptId = null; entry.Upload = null; entry.Accepted = false; entry.UploadHash = null; }

    private async Task<bool> OfficeBaselineMatchesAsync(OfficeRemoteSnapshot baseline, CancellationToken token)
    {
        try
        {
            var current = await ReadOfficeRemoteAsync(baseline.Metadata.Item.Path, token).ConfigureAwait(false);
            return SameOfficeMetadata(baseline.Metadata, current.Metadata) &&
                string.Equals(baseline.Md5, current.Md5, StringComparison.OrdinalIgnoreCase);
        }
        catch (IOException error) when (error.Message == "office.target-changed") { return false; }
    }

    private async Task<MutationErrorCategory?> OfficePermissionAsync(string path, CancellationToken token)
    {
        var result = await _api.CheckFileMutationPermissionAsync(_profile, _session,
            _capabilities["SYNO.FileStation.CheckPermission"], MutationParent(path),
            $"LanStash-Write-Check-{Guid.NewGuid():N}.tmp", token).ConfigureAwait(false);
        return result.Status == FilePermissionTransportStatus.Allowed ? null : result.ErrorCategory ?? MutationErrorCategory.Permission;
    }

    private static bool SameOfficeMetadata(FileEntryMetadata a, FileEntryMetadata? b) => b is not null &&
        a.Item.Path == b.Item.Path && a.Item.Name == b.Item.Name && a.Item.IsDirectory == b.Item.IsDirectory &&
        a.Item.Size == b.Item.Size && a.Item.ModifiedAt == b.Item.ModifiedAt && a.Type == b.Type && a.MountPointType == b.MountPointType;
}
