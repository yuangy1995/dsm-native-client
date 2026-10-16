using System.Security.Cryptography;
using LanStash.Domain;
using static LanStash.Infrastructure.SynologyPhotosCodec;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    private async Task ReviewAutomaticCoreAsync(PhotoAutomaticTask task, CancellationToken token)
    {
        if (task.Record.State is not (SynologyPhotoChangeState.Submitting or SynologyPhotoChangeState.PendingReview)) return;
        try
        {
            CheckAutomaticOwner(task.Record); var generation = Volatile.Read(ref _accessGeneration); var candidate = task.Record.Candidate;
            await FreshManagementAccessAsync([candidate.Space], token).ConfigureAwait(false);
            AutomaticSource? source = null;
            if (candidate.SourcePhoto is { } original)
            {
                source = (await AutomaticSourcesAsync(original, token).ConfigureAwait(false)).SingleOrDefault(item =>
                    item.Id == candidate.UnitId && item.Filename == candidate.Filename && item.Video == (candidate.TypeCode != 0));
                if (source is null) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
            }
            else if (candidate.Space == SynologyPhotoSpace.Shared && !_managesSharedSpace) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
            if (task.Record.FailureKind is { } kind)
            {
                // 后台有限候选批次不提供完成证据；只有原单元真实的失败状态可以收尾。
                var thumbnail = source is null ? null : OptionalObject(source.Additional, "thumbnail");
                var recorded = kind == AutomaticFailureKind.Photo
                    ? thumbnail is not null && OptionalText(thumbnail, "xl") == "broken" && OptionalText(thumbnail, "sm") == "broken"
                    : source is not null && OptionalText(source.Additional, "video_convert_status") == "broken";
                if (!recorded) return;
                RequireGeneration(generation, token); CheckAutomaticOwner(task.Record);
                await SaveAutomaticAsync(task, task.Record with { State = SynologyPhotoChangeState.Failed, FailureRecorded = true, Failure = SynologyPhotoFailure.Media }).ConfigureAwait(false);
                return;
            }
            if (!task.Record.Submitted || !task.Record.Acknowledged && !await AutomaticMediaMatchesAsync(task.Record, token).ConfigureAwait(false)) return;
            // 大视频读取可能跨越权限变化；完成前刷新账号与共享角色。
            await FreshManagementAccessAsync([candidate.Space], token).ConfigureAwait(false);
            if (candidate.SourcePhoto is null && candidate.Space == SynologyPhotoSpace.Shared && !_managesSharedSpace)
                throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
            SynologyPhoto? current = null;
            if (candidate.SourcePhoto is { } photo)
            {
                _ = await AutomaticSourcesAsync(photo, token).ConfigureAwait(false);
                current = await DetailsAsync(photo with { AlbumContext = null }, token).ConfigureAwait(false);
                if (current.Id != photo.Id || current.Filename != photo.Filename || current.SizeBytes != photo.SizeBytes || current.FolderId != photo.FolderId ||
                    current.IndexedAt != photo.IndexedAt || current.MediaType != photo.MediaType) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
                current = current with { AlbumContext = photo.AlbumContext };
            }
            RequireGeneration(generation, token); CheckAutomaticOwner(task.Record); task.Updated = current;
            await SaveAutomaticAsync(task, task.Record with { State = SynologyPhotoChangeState.Completed, Failure = null }).ConfigureAwait(false);
        }
        catch (Exception error) when (AutomaticError(error)) { RequireManagementStore(); }
    }
    private async Task<bool> AutomaticMediaMatchesAsync(PhotoAutomaticRecord record, CancellationToken token)
    {
        var candidate = record.Candidate;
        if (candidate.NeedsThumbnail)
        {
            if (record.ThumbnailDigests is not { Length: 3 }) return false;
            var sizes = new[] { SynologyPhotoThumbnailSize.Large, SynologyPhotoThumbnailSize.Small, SynologyPhotoThumbnailSize.Medium };
            for (var i = 0; i < sizes.Length; i++)
            {
                var bytes = await _api.ReadPhotoThumbnailSizeAsync(_profile, _session, new(candidate.UnitId, "") { Space = candidate.Space }, sizes[i], token).ConfigureAwait(false);
                if (Convert.ToHexString(SHA256.HashData(bytes)) != record.ThumbnailDigests[i]) return false;
            }
        }
        if (!candidate.NeedsVideo) return true;
        if (record.VideoSignature is not { IsValid: true } expected) return false;
        var directory = AutomaticDirectory(); var path = Path.Combine(directory, "review.mov");
        try
        {
            using var media = await _api.OpenPhotoMediaAsync(_profile, _session, new(Capability("Streaming", 2, candidate.Space), "streaming",
                Parameters(("id", candidate.UnitId), ("type", "unit"), ("quality", "orig_h264"), ("use_mov", true))), token).ConfigureAwait(false);
            if (media.Length <= 0 || media.ContentType is not ("video/mp4" or "video/quicktime" or "application/octet-stream")) return false;
            await using (var output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None, 64 * 1024, true))
            {
                for (long offset = 0; offset < media.Length;)
                {
                    var count = (int)Math.Min(1024 * 1024, media.Length - offset); var bytes = await media.ReadAsync(offset, count, token).ConfigureAwait(false);
                    if (bytes.Length != count) return false;
                    await output.WriteAsync(bytes, token).ConfigureAwait(false); offset += bytes.Length;
                }
            }
            return expected.Matches(await _previewConverter.VideoSignatureAsync(path, token).ConfigureAwait(false));
        }
        finally { if (File.Exists(path)) File.Delete(path); Directory.Delete(directory); }
    }
}
