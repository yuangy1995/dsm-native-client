using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using static LanStash.Infrastructure.SynologyPhotosCodec;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    public async Task<IReadOnlyList<SynologyPhotoChoice>> TagsAsync(SynologyPhotoSpace space, int offset, int limit, CancellationToken cancellationToken = default)
    {
        var fields = PageParameters(offset, limit); Add(fields, Parameters(("additional", new[] { "thumbnail" })));
        var data = await ReadAsync("Browse.GeneralTag", 1, "list", fields, cancellationToken, space).ConfigureAwait(false);
        return Collections(data, limit).Select(item => new SynologyPhotoChoice(item.Id, item.Name)).ToArray();
    }
    private PhotoChangeRecord ChangeRecord(Guid id, SynologyPhotoEdit edit)
    {
        if (!Enum.IsDefined(edit.Kind) || !Enum.IsDefined(edit.Space) || edit.Photos.Count > 100 ||
            edit.Photos.Count == 0 && edit.Kind != SynologyPhotoEditKind.CreateTag ||
            edit.Photos.DistinctBy(photo => photo.Id).Count() != edit.Photos.Count ||
            edit.TagIds.Any(tag => tag <= 0) || edit.TagIds.Distinct().Count() != edit.TagIds.Count) throw Invalid();
        switch (edit.Kind)
        {
            case SynologyPhotoEditKind.Description when edit.Text is null: throw Invalid();
            case SynologyPhotoEditKind.CreateTag when string.IsNullOrWhiteSpace(edit.Text): throw Invalid();
            case SynologyPhotoEditKind.Rating when edit.Value is not (>= 0 and <= 5): throw Invalid();
            case SynologyPhotoEditKind.Date or SynologyPhotoEditKind.ShiftDates when edit.Value is null: throw Invalid();
            case SynologyPhotoEditKind.AddTags or SynologyPhotoEditKind.RemoveTags when edit.TagIds.Count == 0: throw Invalid();
            case SynologyPhotoEditKind.Rotate when edit.Photos.Count != 1 || !edit.Photos[0].SupportsRotation: throw Invalid();
        }
        var spaces = edit.Photos.Select(photo => photo.Id.Space).Distinct().ToArray();
        if (spaces.Length > 1 && edit.Kind is not (SynologyPhotoEditKind.Rating or SynologyPhotoEditKind.Date or SynologyPhotoEditKind.ShiftDates) ||
            spaces.Length == 1 && spaces[0] != edit.Space) throw Invalid();
        var entries = edit.Photos.Select(photo =>
        {
            RequirePhoto(photo); RequireAccess(photo.Id.Space);
            long? expected = edit.Kind switch
            {
                SynologyPhotoEditKind.Rating or SynologyPhotoEditKind.Date => edit.Value,
                SynologyPhotoEditKind.ShiftDates => ShiftPhotoDate(photo.TakenAt, edit.Value!.Value),
                SynologyPhotoEditKind.Rotate => photo.CounterClockwiseOrientation,
                _ => null,
            };
            if (edit.Kind is SynologyPhotoEditKind.Date or SynologyPhotoEditKind.ShiftDates)
            {
                try { if (expected < 0) throw Invalid(); _ = DateTimeOffset.FromUnixTimeSeconds(expected!.Value); }
                catch (ArgumentOutOfRangeException) { throw Invalid(); }
            }
            return new PhotoChangeEntry(MinimalManagedPhoto(photo), expected,
                photo.Description is null ? null : PhotoTextHash(photo.Description), photo.Tags?.Select(tag => tag.Id).ToArray());
        }).ToArray();
        var textHash = edit.Kind is SynologyPhotoEditKind.Description or SynologyPhotoEditKind.CreateTag ? PhotoTextHash(edit.Text!) : null;
        var tags = edit.TagIds.Order().ToArray();
        var fingerprint = PhotoTextHash(JsonSerializer.Serialize(new { edit.Kind, edit.Space, Text = textHash, Tags = tags, Items = entries }));
        return new(1, id, ProfileId, UploadOwner(), fingerprint, edit.Kind, edit.Space, textHash, tags, entries);
    }
    private static long ShiftPhotoDate(DateTimeOffset original, long seconds)
    {
        try { return checked(original.ToUnixTimeSeconds() + seconds); }
        catch (OverflowException) { throw Invalid(); }
    }
    public Task PrepareEditAsync(SynologyPhotoEdit edit, CancellationToken cancellationToken = default) =>
        PrepareChangeRecordAsync(ChangeRecord(Guid.NewGuid(), edit), cancellationToken);
    private async Task PrepareChangeRecordAsync(PhotoChangeRecord record, CancellationToken token)
    {
        RequireManagementStore(); var generation = Volatile.Read(ref _accessGeneration);
        CheckChangeOwner(record); await FreshManagementAccessAsync(record, token).ConfigureAwait(false);
        var mixed = record.Items.Select(item => item.Original.Id.Space).Distinct().Count() > 1;
        if (mixed && !_managesSharedSpace) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        if (record.Kind == SynologyPhotoEditKind.CreateTag) _ = Capability("Browse.GeneralTag", 1, record.Space);
        var current = new List<SynologyPhoto>();
        foreach (var entry in record.Items)
        {
            _ = Capability("Browse.Item", record.Kind is SynologyPhotoEditKind.AddTags or SynologyPhotoEditKind.RemoveTags or SynologyPhotoEditKind.CreateTag ? 1 : 2, entry.Original.Id.Space);
            current.Add(await EditablePhotoAsync(entry, record.Kind, token).ConfigureAwait(false));
        }
        if (mixed)
        {
            foreach (var albumId in current.Select(photo => photo.AlbumContext?.AlbumId).OfType<long>().Distinct())
            {
                var album = await ManagementAlbumAsync(albumId, token).ConfigureAwait(false);
                if (Positive(album, "owner_user_id") != _currentUserId && current.Where(photo => photo.AlbumContext?.AlbumId == albumId)
                    .Any(photo => photo.AlbumContext?.ProviderUserId != _currentUserId)) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
            }
        }
        RequireGeneration(generation, token); CheckChangeOwner(record);
    }
    private void CheckChangeOwner(PhotoChangeRecord record)
    {
        if (record.Owner != UploadOwner()) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        RequireAccess(record.Space);
        foreach (var space in record.Items.Select(item => item.Original.Id.Space).Distinct()) RequireAccess(space);
        if (record.Items.Select(item => item.Original.Id.Space).Distinct().Count() > 1 && !_managesSharedSpace)
            throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
    }
    private Task FreshManagementAccessAsync(PhotoChangeRecord record, CancellationToken token) =>
        FreshManagementAccessAsync(record.Items.Select(item => item.Original.Id.Space).Append(record.Space).Distinct().ToArray(), token);
    private async Task FreshManagementAccessAsync(IReadOnlyList<SynologyPhotoSpace> spaces, CancellationToken token)
    {
        var info = await ReadAsync("UserInfo", 1, "me", cancellationToken: token, space: null).ConfigureAwait(false);
        if (!Boolean(info, "enabled") || Positive(info, "id") != _currentUserId) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        var user = await ReadAsync("Setting.User", 1, "get", cancellationToken: token, space: null).ConfigureAwait(false);
        if (spaces.Contains(SynologyPhotoSpace.Personal) && !Boolean(user, "enable_home_service")) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        if (spaces.Contains(SynologyPhotoSpace.Shared))
        {
            if (MembersBusy()) throw new SynologyPhotoException(SynologyPhotoFailure.UploadBusy);
            var team = await ReadAsync("Setting.TeamSpace", 1, "get", cancellationToken: token, space: null).ConfigureAwait(false);
            var role = Text(user, "team_space_permission");
            if (!Boolean(team, "enabled") || role is not ("entry" or "management") || (role == "management") != _managesSharedSpace)
                throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        }
    }
    private async Task<JsonObject> ManagementAlbumAsync(long id, CancellationToken token)
    {
        var payload = await ReadAsync("Browse.Album", 4, "get", Parameters(("id", new[] { id }), ("additional", new[] { "sharing_info" })), token, null).ConfigureAwait(false);
        var entries = List(payload);
        if (entries.Length != 1 || Positive(entries[0], "id") != id) throw Invalid();
        return entries[0];
    }
    private async Task<JsonObject> ManagedPhotoFolderAsync(long id, SynologyPhotoSpace space, bool manage, CancellationToken token)
        => await ReadPhotoFolderAsync(id, space, manage ? PhotoFolderRight.Manage : PhotoFolderRight.View, token).ConfigureAwait(false);
    private async Task<SynologyPhoto> EditablePhotoAsync(PhotoChangeEntry entry, SynologyPhotoEditKind kind, CancellationToken token)
    {
        var photo = entry.Original; RequirePhoto(photo); RequireAccess(photo.Id.Space);
        if (photo.AlbumContext is { } sourceAlbum) await CheckAlbumBusyAsync(sourceAlbum.AlbumId, token).ConfigureAwait(false);
        await CheckManagedFolderConflictsAsync(photo.FolderId, photo.Id.Space, null, token).ConfigureAwait(false);
        if (RecognitionPhotoBusy(photo.Id) || PreviewPhotoBusy(photo.Id) || FilePhotoBusy(photo.Id) || AlbumPhotoBusy(photo.Id)) throw new SynologyPhotoException(SynologyPhotoFailure.UploadBusy);
        var current = await DetailsAsync(photo, token).ConfigureAwait(false);
        if (!photo.IsSameDeletionTarget(current) || photo.AlbumContext != current.AlbumContext) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
        await AuthorizePhotoEditAsync(current, token).ConfigureAwait(false);
        var conflict = kind switch
        {
            SynologyPhotoEditKind.Description => (current.Description is null ? null : PhotoTextHash(current.Description)) != entry.OriginalTextHash,
            SynologyPhotoEditKind.Rating => current.Rating != photo.Rating,
            SynologyPhotoEditKind.Rotate => !current.SupportsRotation || current.Orientation != photo.Orientation || current.Width != photo.Width || current.Height != photo.Height,
            _ => false,
        };
        if (conflict) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
        if (kind is SynologyPhotoEditKind.AddTags or SynologyPhotoEditKind.RemoveTags or SynologyPhotoEditKind.CreateTag && current.Tags is null) throw Invalid();
        return current;
    }
    private async Task AuthorizePhotoEditAsync(SynologyPhoto photo, CancellationToken token)
    {
        if (photo.AlbumContext is { } context)
        {
            if (photo.Id.Space == SynologyPhotoSpace.Shared)
            { if (!_managesSharedSpace) throw new SynologyPhotoException(SynologyPhotoFailure.Permission); }
            else if (photo.AlbumContext?.ProviderUserId != _currentUserId)
            {
                if (context.OwnerUserId != _currentUserId) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
                var album = await ManagementAlbumAsync(context.AlbumId, token).ConfigureAwait(false);
                if (Positive(album, "owner_user_id") != _currentUserId || Text(album, "type") != "condition" && !Permission(album, "freeze_album"))
                    throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
            }
        }
        else _ = await ManagedPhotoFolderAsync(photo.FolderId, photo.Id.Space, true, token).ConfigureAwait(false);
    }
}
