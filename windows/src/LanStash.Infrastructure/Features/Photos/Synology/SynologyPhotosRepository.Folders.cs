using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using static LanStash.Infrastructure.SynologyPhotosCodec;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    public bool SupportsFolderManagement => SupportsManagement;
    private enum PhotoFolderRight { View, Manage, Upload, Download }
    private async Task<JsonObject> ReadPhotoFolderAsync(long? id, SynologyPhotoSpace space, PhotoFolderRight right, CancellationToken token)
    {
        var fields = Parameters(("additional", new[] { "access_permission", "thumbnail" }));
        if (id is { } value) { RequirePositive(value); fields["id"] = JsonSerializer.Serialize(value); }
        else fields["name"] = JsonSerializer.Serialize("/");
        var data = await ReadAsync("Browse.Folder", 2, "get", fields, token, space).ConfigureAwait(false);
        var folder = Object(data["folder"]);
        if (id is not null && Positive(folder, "id") != id) throw Invalid();
        var permission = OptionalObject(OptionalObject(folder, "additional") ?? new(), "access_permission");
        var granted = right switch
        {
            PhotoFolderRight.Manage => Permission(permission, "manage"),
            PhotoFolderRight.Upload => Permission(permission, "manage") || space == SynologyPhotoSpace.Shared && Permission(permission, "upload"),
            PhotoFolderRight.Download => Permission(permission, "download"), _ => true,
        };
        if (!(space == SynologyPhotoSpace.Shared && _managesSharedSpace) && (!Permission(permission, "view") || !granted))
            throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        return folder;
    }
    private static string SortField(SynologyPhotoSortField field) => field switch
    {
        SynologyPhotoSortField.TakenTime => "takentime", SynologyPhotoSortField.Filename => "filename",
        SynologyPhotoSortField.FileSize => "filesize", SynologyPhotoSortField.MediaType => "item_type", _ => throw Invalid(),
    };
    private static SynologyPhotoSortField? ParseSortField(string? field) => field switch
    { "takentime" => SynologyPhotoSortField.TakenTime, "filename" => SynologyPhotoSortField.Filename,
      "filesize" => SynologyPhotoSortField.FileSize, "item_type" => SynologyPhotoSortField.MediaType, _ => null };
    private static bool? SortDirection(string? value) => value switch { "asc" => false, "desc" => true, _ => null };
    private static SynologyPhotoSort? ExplicitFolderSort(JsonObject folder) =>
        ParseSortField(OptionalText(folder, "sort_by")) is { } field && SortDirection(OptionalText(folder, "sort_direction")) is { } descending
            ? new(field, descending) : null;
    private static SynologyPhotoFolder PhotoFolder(JsonObject folder, SynologyPhotoSpace space)
    {
        var value = new SynologyPhotoFolder(space, Positive(folder, "id"), Number(folder, "parent"), Text(folder, "name")) { Sort = ExplicitFolderSort(folder) };
        ValidatePhotoFolder(value); return value;
    }
    private static void ValidatePhotoFolder(SynologyPhotoFolder folder)
    {
        if (!Enum.IsDefined(folder.Space) || folder.Id <= 0 || folder.ParentId < 0 || string.IsNullOrEmpty(folder.Path) ||
            !folder.Path.StartsWith('/') || folder.Path.Contains('\0') || folder.Path != "/" &&
            folder.Path[1..].Split('/').Any(part => part.Length == 0 || part is "." or "..") ||
            folder.Sort is { } sort && !Enum.IsDefined(sort.Field)) throw Invalid();
    }
    public async Task<SynologyPhotoFolder> FolderAsync(long? id, SynologyPhotoSpace space, CancellationToken cancellationToken = default)
    {
        var raw = await ReadPhotoFolderAsync(id, space, PhotoFolderRight.View, cancellationToken).ConfigureAwait(false);
        var folder = PhotoFolder(raw, space);
        if (id is null && !folder.IsRoot) throw Invalid();
        if (folder.Sort is not null) return folder;
        var settings = await ReadAsync("Setting.User", 1, "get", cancellationToken: cancellationToken, space: null).ConfigureAwait(false);
        return folder with { Sort = new(ParseSortField(OptionalText(raw, "sort_by")) ?? ParseSortField(OptionalText(settings, "item_sort_by")) ?? SynologyPhotoSortField.TakenTime,
            SortDirection(OptionalText(raw, "sort_direction")) ?? SortDirection(OptionalText(settings, "sort_direction")) ?? false) };
    }
    private static bool SamePhotoFolder(SynologyPhotoFolder left, SynologyPhotoFolder right) =>
        left.Space == right.Space && left.Id == right.Id && left.ParentId == right.ParentId && left.Path == right.Path;
    private static bool FolderContains(string parent, string path) => parent == "/" || path == parent || path.StartsWith(parent + "/", StringComparison.Ordinal);
    private static string ChildFolderPath(string parent, string name) => parent == "/" ? "/" + name : parent + "/" + name;
    private static string RenamedFolderPath(SynologyPhotoFolder folder, string name) => folder.Path[..(folder.Path.LastIndexOf('/') + 1)] + name;
    private static bool FolderRenameContains(PhotoFolderChangeRecord record, string path) => record.Edit.Kind == SynologyPhotoFolderEditKind.Rename &&
        (FolderContains(record.Edit.Folder.Path, path) || FolderContains(RenamedFolderPath(record.Edit.Folder, record.Edit.Name!), path));
    private static void ValidateFolderEdit(SynologyPhotoFolderEdit edit)
    {
        ValidatePhotoFolder(edit.Folder);
        if (!Enum.IsDefined(edit.Kind)) throw Invalid();
        if (edit.Kind == SynologyPhotoFolderEditKind.Cover)
        {
            if (edit.Folder.IsRoot || edit.Photo is not { AlbumContext: null } photo || photo.Id.Space != edit.Folder.Space || photo.Id.ItemId <= 0 || photo.FolderId <= 0) throw Invalid();
            return;
        }
        if (edit.Kind == SynologyPhotoFolderEditKind.Sort)
        { if (edit.Sort is null || !Enum.IsDefined(edit.Sort.Field)) throw Invalid(); return; }
        var name = edit.Name;
        if (!SynologyPhotoFolderEdit.IsValidName(name, edit.Kind == SynologyPhotoFolderEditKind.Rename) ||
            edit.Kind == SynologyPhotoFolderEditKind.Rename && edit.Folder.IsRoot) throw Invalid();
    }
    private async Task PrepareFolderEditAsync(PhotoFolderChangeRecord record, CancellationToken token)
    {
        var edit = record.Edit; CheckFolderOwner(record); ValidateFolderEdit(edit);
        CheckFolderSharingLocks(edit.Kind == SynologyPhotoFolderEditKind.Create ? edit.Folder with { Path = ChildFolderPath(edit.Folder.Path, edit.Name!) } : edit.Folder,
            includeChildren: edit.Kind == SynologyPhotoFolderEditKind.Rename);
        await CheckFileFolderConflictsAsync(edit.Folder.Id, edit.Folder.Space, edit.Kind == SynologyPhotoFolderEditKind.Create ? edit.Name : null,
            Guid.Empty, token, edit.Kind == SynologyPhotoFolderEditKind.Rename).ConfigureAwait(false);
        await FreshManagementAccessAsync([edit.Folder.Space], token).ConfigureAwait(false);
        var right = edit.Kind == SynologyPhotoFolderEditKind.Sort ? PhotoFolderRight.View :
            edit.Kind == SynologyPhotoFolderEditKind.Create ? PhotoFolderRight.Upload : PhotoFolderRight.Manage;
        var current = PhotoFolder(await ReadPhotoFolderAsync(edit.Folder.Id, edit.Folder.Space, right, token).ConfigureAwait(false), edit.Folder.Space);
        if (!SamePhotoFolder(current, edit.Folder)) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
        if (edit.Kind == SynologyPhotoFolderEditKind.Sort && (await FolderAsync(edit.Folder.Id, edit.Folder.Space, token).ConfigureAwait(false)).Sort != edit.Folder.Sort)
            throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
        _ = Capability("Browse.Folder", edit.Kind == SynologyPhotoFolderEditKind.Cover ? 2 : 1, edit.Folder.Space);
        if (edit.Kind == SynologyPhotoFolderEditKind.Cover)
        {
            var photo = edit.Photo!; RequirePhoto(photo);
            if (RecognitionPhotoBusy(photo.Id) || PreviewPhotoBusy(photo.Id) || FilePhotoBusy(photo.Id) || AlbumPhotoBusy(photo.Id) || _changes.Tasks.Values.Where(task => task.Record.Owner == record.Owner).Any(task => task.Record.Items.Any(item =>
                item.Original.Id == photo.Id && item.State is not (SynologyPhotoChangeState.Completed or SynologyPhotoChangeState.Cancelled)))) throw new SynologyPhotoException(SynologyPhotoFailure.UploadBusy);
            await CheckManagedFolderConflictsAsync(photo.FolderId, photo.Id.Space, null, token).ConfigureAwait(false);
            if (!photo.IsSameDeletionTarget(await DetailsAsync(photo, token).ConfigureAwait(false))) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
            var source = PhotoFolder(await ReadPhotoFolderAsync(photo.FolderId, photo.Id.Space, PhotoFolderRight.View, token).ConfigureAwait(false), photo.Id.Space);
            if (!FolderContains(current.Path, source.Path)) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        }
        if (edit.Kind == SynologyPhotoFolderEditKind.Rename)
        {
            await CheckRecognitionFolderLocksAsync(edit.Folder, token, true).ConfigureAwait(false);
            await CheckRequestFolderLocksAsync(edit.Folder, token).ConfigureAwait(false);
            var photos = _changes.Tasks.Values.Where(task => task.Record.Owner == record.Owner).SelectMany(task => task.Record.Items)
                .Where(item => item.Original.Id.Space == edit.Folder.Space && item.State is not (SynologyPhotoChangeState.Completed or SynologyPhotoChangeState.Cancelled))
                .Select(item => item.Original).Concat(_changes.Albums.Values.Where(task => task.Record.Owner == record.Owner && ActiveAlbumChange(task.Record))
                    .SelectMany(task => task.Record.Edit.Photos).Where(photo => photo.Id.Space == edit.Folder.Space));
            foreach (var id in photos.Select(photo => photo.FolderId).Distinct())
            {
                var parent = PhotoFolder(await ReadPhotoFolderAsync(id, edit.Folder.Space, PhotoFolderRight.View, token).ConfigureAwait(false), edit.Folder.Space);
                if (FolderContains(edit.Folder.Path, parent.Path)) throw new SynologyPhotoException(SynologyPhotoFailure.UploadBusy);
            }
        }
        await CheckFolderUploadConflictsAsync(record, token).ConfigureAwait(false);
    }
    private async Task CheckFolderUploadConflictsAsync(PhotoFolderChangeRecord record, CancellationToken token)
    {
        if (_uploadStore is null) return; await LoadUploadsAsync().ConfigureAwait(false); token.ThrowIfCancellationRequested();
        var edit = record.Edit;
        foreach (var upload in _uploads.Tasks.Values.Where(task => task.Record.Owner == record.Owner && task.Record.Target.Space == edit.Folder.Space && !task.Record.Target.DirectToAlbum))
        {
            if (edit.Kind == SynologyPhotoFolderEditKind.Create && upload.Record.Items.Any(item =>
                item.State is SynologyPhotoUploadState.PreparingFolders or SynologyPhotoUploadState.PendingReview &&
                item.FolderParent == edit.Folder.Id && item.FolderName == edit.Name)) throw new SynologyPhotoException(SynologyPhotoFailure.UploadBusy);
            if (edit.Kind != SynologyPhotoFolderEditKind.Rename || !upload.Record.Items.Any(item =>
                item.State is not (SynologyPhotoUploadState.Completed or SynologyPhotoUploadState.Skipped or SynologyPhotoUploadState.Cancelled))) continue;
            if (upload.Record.Root is { } root)
            {
                var target = await FolderAsync(root.Id, edit.Folder.Space, token).ConfigureAwait(false);
                if (FolderContains(edit.Folder.Path, target.Path)) throw new SynologyPhotoException(SynologyPhotoFailure.UploadBusy);
            }
        }
    }
    private async Task CheckManagedFolderConflictsAsync(long id, SynologyPhotoSpace space, string? childName, CancellationToken token, Guid exceptFiles = default, Guid exceptRecognition = default, Guid exceptPreview = default)
    {
        if (_managementStore is null) return;
        await LoadChangesAsync().ConfigureAwait(false); var owner = UploadOwner();
        if (space == SynologyPhotoSpace.Shared && MembersBusy()) throw new SynologyPhotoException(SynologyPhotoFailure.UploadBusy);
        if (AutomaticBackgroundBusy(space, exceptPreview) || RecognitionFolders(space, exceptRecognition).Concat(PreviewFolders(space, exceptPreview)).Contains(id)) throw new SynologyPhotoException(SynologyPhotoFailure.UploadBusy);
        if (space == SynologyPhotoSpace.Shared && _changes.FolderSharing.Values.Any(task => task.Record.Owner == owner && ActiveFolderSharing(task.Record)))
        {
            var current = PhotoFolder(await ReadPhotoFolderAsync(id, space, PhotoFolderRight.View, token).ConfigureAwait(false), space);
            CheckFolderSharingLocks(childName is null ? current : current with { Path = ChildFolderPath(current.Path, childName) });
        }
        await CheckFileFolderConflictsAsync(id, space, childName, exceptFiles, token).ConfigureAwait(false);
        var records = _changes.Folders.Values.Where(task => task.Record.Owner == owner && ActiveFolderChange(task.Record) && task.Record.Edit.Folder.Space == space)
            .Select(task => task.Record).ToArray();
        if (childName is not null && records.Any(record => record.Edit.Kind == SynologyPhotoFolderEditKind.Create && record.Edit.Folder.Id == id && record.Edit.Name == childName))
            throw new SynologyPhotoException(SynologyPhotoFailure.UploadBusy);
        if (!records.Any(record => record.Edit.Kind == SynologyPhotoFolderEditKind.Rename)) return;
        var folder = PhotoFolder(await ReadPhotoFolderAsync(id, space, PhotoFolderRight.View, token).ConfigureAwait(false), space);
        if (records.Any(record => record.Edit.Kind == SynologyPhotoFolderEditKind.Rename && record.Edit.Folder.Id == id || FolderRenameContains(record, folder.Path)))
            throw new SynologyPhotoException(SynologyPhotoFailure.UploadBusy);
    }
}
