using System.Security.Cryptography;
using LanStash.Domain;
using static LanStash.Infrastructure.SynologyPhotosCodec;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    private static bool AutomaticError(Exception error) => PreviewError(error) || error is SynologyPhotoConversionException or NotSupportedException;
    private static SynologyPhotoFailure AutomaticFailure(Exception error) => error is SynologyPhotoConversionException or NotSupportedException
        ? SynologyPhotoFailure.Media : PreviewFailure(error);
    public async Task<SynologyPhotoAutomaticPreview> GenerateAutomaticPreviewAsync(Guid operationId, SynologyPhotoAutomaticCandidate candidate,
        SynologyPhotoConversionSupport support, CancellationToken cancellationToken = default)
    {
        if (operationId == Guid.Empty || candidate.ProfileId != ProfileId || candidate.SourcePhoto is { } original &&
            (original.Id.ProfileId != ProfileId || original.Id.Space != candidate.Space)) throw Invalid();
        candidate = candidate with { SourcePhoto = candidate.SourcePhoto is { } source ? MinimalManagedPhoto(source) with { Thumbnail = source.Thumbnail } : null };
        var record = new PhotoAutomaticRecord(operationId, UploadOwner(), candidate, support);
        await LoadChangesAsync().ConfigureAwait(false); PhotoAutomaticTask task; var existing = false;
        await _changes.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (_changes.Tasks.ContainsKey(operationId) || _changes.Folders.ContainsKey(operationId) || _changes.Files.ContainsKey(operationId) ||
                _changes.Albums.ContainsKey(operationId) || _changes.Sharing.ContainsKey(operationId) || _changes.Temporary.ContainsKey(operationId) ||
                _changes.Requests.ContainsKey(operationId) || _changes.FolderSharing.ContainsKey(operationId) || _changes.Recognition.ContainsKey(operationId) || _changes.Previews.ContainsKey(operationId) || _changes.Settings.ContainsKey(operationId))
                throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
            if (_changes.Automatic.TryGetValue(operationId, out task!))
            {
                CheckAutomaticOwner(task.Record);
                if (task.Record.Candidate != candidate || task.Record.Support != support) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
                existing = true;
            }
            else
            {
                if (support != await _previewConverter.SupportAsync(cancellationToken).ConfigureAwait(false)) throw new SynologyPhotoException(SynologyPhotoFailure.Unavailable);
                await ValidateAutomaticStepAsync(record, cancellationToken).ConfigureAwait(false);
                task = new(record); await SaveAutomaticAsync(task, record).ConfigureAwait(false); _changes.Automatic.TryAdd(operationId, task);
            }
        }
        finally { _changes.Gate.Release(); }
        if (existing) return await ReviewAutomaticPreviewAsync(operationId, cancellationToken).ConfigureAwait(false);
        await task.Gate.WaitAsync(CancellationToken.None).ConfigureAwait(false); task.Running = true;
        var owner = _changes.Owners.GetOrAdd(record.Owner, _ => new(1, 1)); var owns = false;
        try
        {
            await owner.WaitAsync(cancellationToken).ConfigureAwait(false); owns = true;
            await ExecuteAutomaticAsync(task, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception error) when (AutomaticError(error))
        {
            RequireManagementStore();
            if (task.Record.State == SynologyPhotoChangeState.Ready)
                await SaveAutomaticAsync(task, task.Record with { State = cancellationToken.IsCancellationRequested ? SynologyPhotoChangeState.Cancelled : SynologyPhotoChangeState.Failed,
                    Failure = AutomaticFailure(error) }).ConfigureAwait(false);
            else throw;
        }
        finally { task.Running = false; if (owns) owner.Release(); task.Gate.Release(); }
        return AutomaticSnapshot(task);
    }
    private async Task ValidateAutomaticStepAsync(PhotoAutomaticRecord record, CancellationToken token)
    {
        CheckAutomaticOwner(record); var generation = Volatile.Read(ref _accessGeneration); var candidate = record.Candidate;
        if (SettingsBusy()) throw new SynologyPhotoException(SynologyPhotoFailure.UploadBusy);
        if (_changes.Automatic.Values.Any(task => task.Record.Id != record.Id && task.Record.Owner == record.Owner && ActiveAutomatic(task.Record) &&
            task.Record.Candidate.Space == candidate.Space && task.Record.Candidate.UnitId == candidate.UnitId)) throw new SynologyPhotoException(SynologyPhotoFailure.UploadBusy);
        if (!await AutomaticPreviewEnabledAsync(token).ConfigureAwait(false)) throw new SynologyPhotoException(SynologyPhotoFailure.Unavailable);
        await ValidateAutomaticCandidateAsync(candidate, record.Support, token).ConfigureAwait(false);
        if (candidate.SourcePhoto is { } photo) await CheckPreviewLocksAsync(record.Id, photo, token).ConfigureAwait(false);
        else if (OtherAutomaticWork(record.Owner)) throw new SynologyPhotoException(SynologyPhotoFailure.UploadBusy);
        RequireGeneration(generation, token); CheckAutomaticOwner(record);
    }
    // 后台单元无法映射到项目或目录；有其他管理任务时不猜测其关联目标。
    private bool OtherAutomaticWork(string owner) =>
        _changes.Tasks.Values.Any(task => task.Record.Owner == owner && (UnresolvedChange(task) || task.Record.Items.Any(item => item.State is not (SynologyPhotoChangeState.Completed or SynologyPhotoChangeState.Cancelled)))) ||
        _changes.Folders.Values.Any(task => task.Record.Owner == owner && ActiveFolderChange(task.Record)) ||
        _changes.Files.Values.Any(task => task.Record.Owner == owner && ActiveFileChange(task.Record)) ||
        _changes.Albums.Values.Any(task => task.Record.Owner == owner && ActiveAlbumChange(task.Record)) ||
        _changes.Sharing.Values.Any(task => task.Record.Owner == owner && ActiveSharing(task.Record)) ||
        _changes.Temporary.Values.Any(task => task.Record.Owner == owner && ActiveTemporary(task.Record)) ||
        _changes.Requests.Values.Any(task => task.Record.Owner == owner && ActiveRequest(task.Record)) ||
        _changes.FolderSharing.Values.Any(task => task.Record.Owner == owner && ActiveFolderSharing(task.Record)) ||
        _changes.Recognition.Values.Any(task => task.Record.Owner == owner && ActiveRecognition(task.Record)) ||
        _changes.Previews.Values.Any(task => task.Record.Owner == owner && task.Record.Items.Any(ActivePreview));
    private static string AutomaticDirectory()
    {
        var path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "LanStash", "Photos", "Automatic", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(path);
        if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) throw new IOException("photos.preview.directory-link");
        return path;
    }
    private async Task ExecuteAutomaticAsync(PhotoAutomaticTask task, CancellationToken token)
    {
        var candidate = task.Record.Candidate; var generation = Volatile.Read(ref _accessGeneration);
        string? directory = null, source = null, video = null;
        try
        {
            await ValidateAutomaticStepAsync(task.Record, token).ConfigureAwait(false);
            directory = AutomaticDirectory(); var extension = Path.GetExtension(candidate.Filename);
            if (extension.Length > 12 || extension.Skip(1).Any(character => !char.IsAsciiLetterOrDigit(character))) extension = "";
            source = Path.Combine(directory, "source" + extension);
            _ = await _api.DownloadPhotoAsync(_profile, _session, new(Capability("Download", 2, candidate.Space), "download",
                Parameters(("unit_id", new[] { candidate.UnitId }))), source, null, false, cancellationToken: token).ConfigureAwait(false);
            await ValidateAutomaticStepAsync(task.Record, token).ConfigureAwait(false); RequireGeneration(generation, token);
            SynologyPhotoConvertedPreview? thumbnail = null;
            if (candidate.NeedsThumbnail)
            {
                try { thumbnail = await _previewConverter.ConvertAsync(source, candidate.TypeCode == 0 ? "photo" : "video", token).ConfigureAwait(false); }
                catch (Exception error) when (WindowsPhotoPreviewConverter.ShouldRecordFailure(error))
                { await RecordAutomaticFailureAsync(task, AutomaticFailureKind.Photo, generation, token).ConfigureAwait(false); return; }
            }
            SynologyPhotoVideoSignature? signature = null;
            if (candidate.NeedsVideo)
            {
                video = Path.Combine(directory, "preview.mp4");
                try { await _previewConverter.ConvertVideoAsync(source, video, token).ConfigureAwait(false); }
                catch (Exception error) when (WindowsPhotoPreviewConverter.ShouldRecordFailure(error))
                { await RecordAutomaticFailureAsync(task, AutomaticFailureKind.Video, generation, token).ConfigureAwait(false); return; }
                // 输出摘要无法读取不等同原媒体损坏，不能据此标记 NAS。
                signature = await _previewConverter.VideoSignatureAsync(video, token).ConfigureAwait(false);
                if (!signature.IsValid) throw new SynologyPhotoConversionException(false);
            }
            var hashes = thumbnail is null ? null : new[] { thumbnail.Large, thumbnail.Small, thumbnail.Medium }.Select(bytes =>
                bytes.Length > 0 ? Convert.ToHexString(SHA256.HashData(bytes)) : throw new SynologyPhotoConversionException(false)).ToArray();
            RequireGeneration(generation, token);
            await AutomaticWriteAsync(task, task.Record with { Submitted = true, ThumbnailDigests = hashes, VideoSignature = signature }, generation,
                ct => _api.UploadPhotoConvertedMediaAsync(_profile, _session, Capability("Upload.ConvertedFile", 3, candidate.Space), candidate.UnitId, thumbnail, video, ct), token).ConfigureAwait(false);
            await ReviewAutomaticCoreAsync(task, token).ConfigureAwait(false);
        }
        catch (Exception error) when (AutomaticError(error))
        {
            RequireManagementStore(); var pending = task.Record.Submitted || task.Record.FailureKind is not null;
            if (task.Record.State is not (SynologyPhotoChangeState.Completed or SynologyPhotoChangeState.Failed))
                await SaveAutomaticAsync(task, task.Record with { State = pending ? SynologyPhotoChangeState.PendingReview : token.IsCancellationRequested ? SynologyPhotoChangeState.Cancelled : SynologyPhotoChangeState.Failed,
                    Failure = AutomaticFailure(error) }).ConfigureAwait(false);
        }
        finally
        {
            if (source is not null && File.Exists(source)) File.Delete(source);
            if (video is not null && File.Exists(video)) File.Delete(video);
            if (directory is not null && Directory.Exists(directory)) Directory.Delete(directory);
        }
    }
    private async Task AutomaticWriteAsync(PhotoAutomaticTask task, PhotoAutomaticRecord submitting, long generation,
        Func<CancellationToken, Task<SynologyPhotoWriteReceipt>> send, CancellationToken token)
    {
        var before = task.Record; var sent = false;
        try
        {
            await ValidateAutomaticStepAsync(before, token).ConfigureAwait(false); RequireGeneration(generation, token);
            await SaveAutomaticAsync(task, submitting with { State = SynologyPhotoChangeState.Submitting }).ConfigureAwait(false);
            await ValidateAutomaticStepAsync(task.Record, token).ConfigureAwait(false); RequireGeneration(generation, token);
            sent = true; var receipt = await send(token).ConfigureAwait(false);
            var marking = submitting.FailureKind is not null;
            await SaveAutomaticAsync(task, task.Record with { State = receipt.Status == SynologyPhotoWriteStatus.Rejected || marking && receipt.Status == SynologyPhotoWriteStatus.Accepted
                    ? SynologyPhotoChangeState.Failed : SynologyPhotoChangeState.PendingReview,
                Acknowledged = !marking && receipt.Status == SynologyPhotoWriteStatus.Accepted,
                FailureRecorded = marking && receipt.Status == SynologyPhotoWriteStatus.Accepted, Failure = receipt.Failure }).ConfigureAwait(false);
            RequireGeneration(generation, token); CheckAutomaticOwner(task.Record);
        }
        catch (Exception error) when (AutomaticError(error))
        {
            RequireManagementStore();
            if (!sent) await SaveAutomaticAsync(task, before with { State = token.IsCancellationRequested ? SynologyPhotoChangeState.Cancelled : SynologyPhotoChangeState.Failed,
                Failure = AutomaticFailure(error) }).ConfigureAwait(false);
            throw;
        }
    }
    private async Task RecordAutomaticFailureAsync(PhotoAutomaticTask task, AutomaticFailureKind kind, long generation, CancellationToken token)
    {
        var candidate = task.Record.Candidate;
        await AutomaticWriteAsync(task, task.Record with { FailureKind = kind }, generation, ct => _api.WritePhotoAsync(_profile, _session,
            Capability("Upload.ConvertedFile", 3, candidate.Space), 3, "set_broken", Parameters(("id", new[] { candidate.UnitId }),
                ("type", new[] { kind == AutomaticFailureKind.Photo ? "photo" : "video" })), ct), token).ConfigureAwait(false);
        await ReviewAutomaticCoreAsync(task, token).ConfigureAwait(false);
    }
}
