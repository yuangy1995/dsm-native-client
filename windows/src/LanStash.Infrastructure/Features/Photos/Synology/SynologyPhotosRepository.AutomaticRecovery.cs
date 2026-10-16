using LanStash.Domain;
using static LanStash.Infrastructure.SynologyPhotosCodec;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    private enum AutomaticFailureKind { Photo, Video }
    private sealed record PhotoAutomaticRecord(Guid Id, string Owner, SynologyPhotoAutomaticCandidate Candidate,
        SynologyPhotoConversionSupport Support, SynologyPhotoChangeState State = SynologyPhotoChangeState.Ready,
        string[]? ThumbnailDigests = null, SynologyPhotoVideoSignature? VideoSignature = null,
        bool Submitted = false, bool Acknowledged = false, AutomaticFailureKind? FailureKind = null,
        bool FailureRecorded = false, SynologyPhotoFailure? Failure = null);
    private sealed class PhotoAutomaticTask(PhotoAutomaticRecord record)
    {
        internal volatile PhotoAutomaticRecord Record = record;
        internal readonly SemaphoreSlim Gate = new(1, 1);
        internal volatile bool Running;
        internal SynologyPhoto? Updated;
    }
    private static bool ActiveAutomatic(PhotoAutomaticRecord record) => record.State is SynologyPhotoChangeState.Ready or
        SynologyPhotoChangeState.Submitting or SynologyPhotoChangeState.PendingReview;
    private bool AutomaticPhotoBusy(SynologyPhotoIdentity id, Guid except = default) => _changes.Automatic.Values.Any(task =>
        task.Record.Id != except && task.Record.Owner == UploadOwner() && ActiveAutomatic(task.Record) && task.Record.Candidate.Space == id.Space &&
        (task.Record.Candidate.SourcePhoto is null || task.Record.Candidate.SourcePhoto.Id == id));
    private bool AutomaticBackgroundBusy(SynologyPhotoSpace space, Guid except = default) => _changes.Automatic.Values.Any(task =>
        task.Record.Id != except && task.Record.Owner == UploadOwner() && ActiveAutomatic(task.Record) && task.Record.Candidate.Space == space && task.Record.Candidate.SourcePhoto is null);
    private static PhotoAutomaticRecord RestoreAutomatic(Guid id, PhotoAutomaticRecord record)
    {
        var candidate = record.Candidate;
        if (id == Guid.Empty || id != record.Id || !UploadHash(record.Owner) || candidate is null || record.Support is null || !record.Support.Available ||
            candidate.ProfileId == Guid.Empty || !Enum.IsDefined(candidate.Space) || !Enum.IsDefined(candidate.Priority) || candidate.UnitId <= 0 ||
            string.IsNullOrWhiteSpace(candidate.Filename) || candidate.TypeCode < 0 || !candidate.NeedsThumbnail && !candidate.NeedsVideo ||
            candidate.NeedsVideo && (candidate.TypeCode == 0 || !record.Support.Video) || !Enum.IsDefined(record.State) ||
            record.Failure is { } failure && !Enum.IsDefined(failure) || record.FailureKind is { } kind && !Enum.IsDefined(kind) ||
            record.ThumbnailDigests is { } hashes && (hashes.Length != 3 || hashes.Any(hash => !UploadHash(hash))) ||
            record.VideoSignature is { } signature && !signature.IsValid ||
            record.Submitted && (record.FailureKind is not null || candidate.NeedsThumbnail && record.ThumbnailDigests is null || candidate.NeedsVideo && record.VideoSignature is null) ||
            record.Acknowledged && !record.Submitted || record.FailureRecorded && record.FailureKind is null ||
            record.FailureKind == AutomaticFailureKind.Photo && !candidate.NeedsThumbnail || record.FailureKind == AutomaticFailureKind.Video && !candidate.NeedsVideo ||
            record.State == SynologyPhotoChangeState.Completed && (!record.Submitted || record.FailureKind is not null) ||
            record.State is SynologyPhotoChangeState.Submitting or SynologyPhotoChangeState.PendingReview && !record.Submitted && record.FailureKind is null)
            throw Invalid();
        if (candidate.SourcePhoto is { } photo && (photo.Id.ProfileId != candidate.ProfileId || photo.Id.Space != candidate.Space ||
            photo.Id.ItemId <= 0 || photo.FolderId <= 0 || photo.SizeBytes < 0 || string.IsNullOrWhiteSpace(photo.Filename) ||
            photo.Thumbnail is { } thumbnail && (thumbnail.UnitId <= 0 || thumbnail.Space != candidate.Space || thumbnail.Type != SynologyPhotoThumbnailType.Unit))) throw Invalid();
        // 未提交的本地转换不自动重跑；提交中的记录只允许读取结果。
        return record with { State = record.State == SynologyPhotoChangeState.Submitting ? SynologyPhotoChangeState.PendingReview :
            record.State == SynologyPhotoChangeState.Ready ? SynologyPhotoChangeState.Failed : record.State };
    }
    private void CheckAutomaticOwner(PhotoAutomaticRecord record)
    {
        RequireManagementStore(); RequireAccess(record.Candidate.Space);
        if (record.Candidate.ProfileId != ProfileId || record.Owner != UploadOwner()) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
    }
    private PhotoAutomaticTask OwnedAutomatic(Guid id)
    {
        if (!_changes.Automatic.TryGetValue(id, out var task)) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        CheckAutomaticOwner(task.Record); return task;
    }
    private async Task SaveAutomaticAsync(PhotoAutomaticTask task, PhotoAutomaticRecord record)
    {
        task.Record = record; await SaveManagementRecordAsync(record.Id, new(1, Automatic: record)).ConfigureAwait(false);
    }
    private static SynologyPhotoAutomaticPreview AutomaticSnapshot(PhotoAutomaticTask task) => new(task.Record.Id, task.Record.Candidate,
        task.Record.State, task.Running, task.Record.FailureRecorded, task.Updated, task.Record.Failure);
    public async Task<IReadOnlyList<SynologyPhotoAutomaticPreview>> AutomaticPreviewsAsync(CancellationToken cancellationToken = default)
    {
        var owner = UploadOwner(); await LoadChangesAsync().ConfigureAwait(false); cancellationToken.ThrowIfCancellationRequested();
        if (owner != UploadOwner()) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        return _changes.Automatic.Values.Where(task => task.Record.Owner == owner).Select(AutomaticSnapshot).ToArray();
    }
    public async Task<SynologyPhotoAutomaticPreview> ReviewAutomaticPreviewAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        await LoadChangesAsync().ConfigureAwait(false); var task = OwnedAutomatic(operationId);
        if (!await task.Gate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return AutomaticSnapshot(task);
        try { await ReviewAutomaticCoreAsync(task, cancellationToken).ConfigureAwait(false); return AutomaticSnapshot(task); }
        finally { task.Gate.Release(); }
    }
}
