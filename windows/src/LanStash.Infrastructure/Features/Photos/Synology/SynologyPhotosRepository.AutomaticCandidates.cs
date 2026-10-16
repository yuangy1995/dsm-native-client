using System.Text.Json.Nodes;
using LanStash.Domain;
using static LanStash.Infrastructure.SynologyPhotosCodec;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    private sealed record AutomaticSource(long Id, string Filename, bool Video, JsonObject Additional);
    public bool SupportsAutomaticPreview(SynologyPhotoSpace space)
    {
        if (!SupportsManagement) return false;
        try { RequireAccess(space); _ = Capability("Upload.ConvertedFile", 3, space); _ = Capability("Download", 2, space); return true; }
        catch (SynologyPhotoException) { return false; }
    }
    public Task<SynologyPhotoConversionSupport> PreviewConversionSupportAsync(CancellationToken cancellationToken = default) => _previewConverter.SupportAsync(cancellationToken);
    public async Task<bool> AutomaticPreviewEnabledAsync(CancellationToken cancellationToken = default)
    {
        var generation = Volatile.Read(ref _accessGeneration); RequireAccess();
        var settings = await ReadAsync("Setting.User", 1, "get", cancellationToken: cancellationToken, space: null).ConfigureAwait(false);
        var result = Boolean(settings, "auto_generate_thumbnail"); RequireGeneration(generation, cancellationToken); return result;
    }
    public async Task<IReadOnlyList<SynologyPhotoAutomaticCandidate>> AutomaticPreviewCandidatesAsync(SynologyPhotoSpace space,
        SynologyPhotoConversionSupport support, CancellationToken cancellationToken = default)
    {
        RequireAccess(space); var generation = Volatile.Read(ref _accessGeneration);
        await FreshManagementAccessAsync([space], cancellationToken).ConfigureAwait(false);
        if (space == SynologyPhotoSpace.Shared && !_managesSharedSpace) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        if (!support.Available) return [];
        var raw = List(await ReadAsync("Upload.ConvertedFile", 3, "list_convert_needed",
            Parameters(("type", support.Hevc ? new[] { "photo", "video", "live_video" } : ["video"]), ("preset", support.Preset)), cancellationToken, space).ConfigureAwait(false));
        var result = raw.Select(item => new SynologyPhotoAutomaticCandidate(ProfileId, space, Positive(item, "unit_id"), Text(item, "filename"),
            Int(item, "type"), AutomaticFlag(item, "need_thumbnail"), AutomaticFlag(item, "need_video"))).ToArray();
        if (result.DistinctBy(item => item.UnitId).Count() != result.Length || result.Any(item => string.IsNullOrWhiteSpace(item.Filename) || item.TypeCode < 0 || item.TypeCode == 0 && item.NeedsVideo)) throw Invalid();
        RequireGeneration(generation, cancellationToken); return result;
    }
    private static bool AutomaticFlag(JsonObject item, string key)
    {
        if (item[key] is not JsonValue value) throw Invalid();
        if (value.TryGetValue<bool>(out var flag)) return flag;
        if (value.TryGetValue<long>(out var integer) && integer is 0 or 1) return integer == 1;
        throw Invalid();
    }
    public async Task<IReadOnlyList<SynologyPhotoAutomaticCandidate>> AutomaticPreviewCandidatesAsync(SynologyPhoto photo,
        SynologyPhotoConversionSupport support, CancellationToken cancellationToken = default)
    {
        RequirePhoto(photo); RequireAccess(photo.Id.Space);
        if (!support.Available) return [];
        var generation = Volatile.Read(ref _accessGeneration);
        await FreshManagementAccessAsync([photo.Id.Space], cancellationToken).ConfigureAwait(false);
        var sources = await AutomaticSourcesAsync(photo, cancellationToken).ConfigureAwait(false); var result = new List<SynologyPhotoAutomaticCandidate>();
        foreach (var source in sources)
        {
            var meta = OptionalObject(source.Additional, "video_meta"); var codec = meta is null ? null : OptionalText(meta, "video_codec");
            var heic = !source.Video && Path.GetExtension(source.Filename).ToLowerInvariant() is ".heic" or ".heif" or ".hif";
            if ((heic || source.Video && codec == "hevc") && !support.Hevc || source.Video && (!support.Video || codec is "vc1" or "wmv3" && !support.Vc1)) continue;
            var thumbnail = OptionalObject(source.Additional, "thumbnail");
            var needsThumbnail = thumbnail is not null && (OptionalText(thumbnail, "xl") == "ame_defect" || OptionalText(thumbnail, "sm") == "ame_defect");
            var needsVideo = source.Video && support.Video && OptionalText(source.Additional, "video_convert_status") == "ame_defect";
            if (!needsThumbnail && !needsVideo) continue;
            var priority = source.Video && codec is "vc1" or "wmv3" ? SynologyPhotoAutomaticPriority.Vc1 :
                source.Video && (codec == "hevc" || photo.MediaType == "live") ? SynologyPhotoAutomaticPriority.HevcOrLiveVideo : SynologyPhotoAutomaticPriority.Standard;
            result.Add(new(ProfileId, photo.Id.Space, source.Id, source.Filename, source.Video ? 1 : 0, needsThumbnail, needsVideo, photo, priority));
        }
        RequireGeneration(generation, cancellationToken); return result;
    }
    private async Task<IReadOnlyList<AutomaticSource>> AutomaticSourcesAsync(SynologyPhoto photo, CancellationToken token)
    {
        RequirePhoto(photo); RequireAccess(photo.Id.Space); var generation = Volatile.Read(ref _accessGeneration);
        var raw = List(await ReadAsync("Browse.Item", 5, "get", Parameters(("id", new[] { photo.Id.ItemId }),
            ("additional", new[] { "thumbnail", "video_meta", "video_convert" })), token, photo.Id.Space).ConfigureAwait(false));
        if (raw.Length != 1) throw Invalid(); var item = raw[0];
        if (Positive(item, "id") != photo.Id.ItemId || Text(item, "filename") != photo.Filename || Number(item, "filesize") != photo.SizeBytes ||
            Positive(item, "folder_id") != photo.FolderId || Text(item, "type") != photo.MediaType || Timestamp(item, "indexed_time") != photo.IndexedAt)
            throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
        var owner = Number(item, "owner_user_id");
        if (photo.Id.Space == SynologyPhotoSpace.Shared ? owner != 0 : owner <= 0 || owner != _currentUserId)
            throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        if (photo.Id.Space == SynologyPhotoSpace.Shared && !_managesSharedSpace)
            _ = await ReadPhotoFolderAsync(photo.FolderId, photo.Id.Space, PhotoFolderRight.Download, token).ConfigureAwait(false);
        var sources = new List<AutomaticSource>();
        if (photo.MediaType == "live")
        {
            var groups = List(await ReadAsync("Browse.Unit", 1, "get", Parameters(("id_item", new[] { photo.Id.ItemId }),
                ("additional", new[] { "orientation", "resolution", "thumbnail", "video_meta", "video_convert" })), token, photo.Id.Space).ConfigureAwait(false));
            if (groups.Length != 1 || Positive(groups[0], "id_item") != photo.Id.ItemId) throw Invalid();
            var units = List(groups[0], "unit"); if (units.Length == 0) throw Invalid();
            foreach (var unit in units)
            {
                var id = Positive(unit, "id"); var type = Text(unit, "live_type"); var filename = Text(unit, "filename");
                var extra = Object(unit["additional"]);
                if (type is not ("photo" or "video") || string.IsNullOrWhiteSpace(filename) || Positive(Object(extra["thumbnail"]), "unit_id") != id) throw Invalid();
                sources.Add(new(id, filename, type == "video", extra));
            }
            if (sources.DistinctBy(source => source.Id).Count() != sources.Count) throw Invalid();
        }
        else
        {
            var extra = Object(item["additional"]); var id = Positive(Object(extra["thumbnail"]), "unit_id");
            if (photo.Thumbnail is { } thumbnail && thumbnail.UnitId != id) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
            sources.Add(new(id, photo.Filename, photo.MediaType is "video" or "video360", extra));
        }
        RequireGeneration(generation, token); return sources;
    }
    private async Task ValidateAutomaticCandidateAsync(SynologyPhotoAutomaticCandidate candidate, SynologyPhotoConversionSupport support, CancellationToken token)
    {
        if (candidate.ProfileId != ProfileId || candidate.UnitId <= 0 || candidate.TypeCode < 0 || !Enum.IsDefined(candidate.Space) ||
            !Enum.IsDefined(candidate.Priority) || !candidate.NeedsThumbnail && !candidate.NeedsVideo ||
            candidate.NeedsVideo && (candidate.TypeCode == 0 || !support.Video) || !SupportsAutomaticPreview(candidate.Space)) throw Invalid();
        var candidates = candidate.SourcePhoto is { } photo ? await AutomaticPreviewCandidatesAsync(photo, support, token).ConfigureAwait(false)
            : await AutomaticPreviewCandidatesAsync(candidate.Space, support, token).ConfigureAwait(false);
        if (!candidates.Contains(candidate)) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
    }
}
