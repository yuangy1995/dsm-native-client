using System.Text.Json.Nodes;
using LanStash.Domain;
using static LanStash.Infrastructure.SynologyPhotosCodec;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    private static void ValidateFileCommand(SynologyPhotoFileCommand command)
    {
        if (!Enum.IsDefined(command.Action) || !Enum.IsDefined(command.Space) || !Enum.IsDefined(command.Duplicate) ||
            command.Photos is null || command.Folders is null || command.Photos.Count + command.Folders.Count == 0 ||
            command.Photos.DistinctBy(photo => photo.Id).Count() != command.Photos.Count ||
            command.Folders.DistinctBy(folder => folder.Id).Count() != command.Folders.Count) throw Invalid();
        foreach (var photo in command.Photos)
            if (photo.Id.Space != command.Space || photo.Id.ItemId <= 0 || photo.FolderId <= 0 || photo.SizeBytes < 0 ||
                string.IsNullOrEmpty(photo.Filename) || photo.Filename.IndexOfAny(['/', '\\', '\0']) >= 0) throw Invalid();
        foreach (var folder in command.Folders)
        {
            ValidatePhotoFolder(folder);
            if (folder.Space != command.Space || folder.IsRoot || folder.ParentId <= 0) throw Invalid();
        }
        if (command.Folders.Count > 0 && (command.Folders.Select(folder => folder.ParentId).Distinct().Count() != 1 ||
            command.Photos.Any(photo => photo.FolderId != command.Folders[0].ParentId || photo.AlbumContext is not null))) throw Invalid();
        if (command.Action == SynologyPhotoFileAction.Delete)
        { if (command.Destination is not null || command.Duplicate != SynologyPhotoFileDuplicate.Skip) throw Invalid(); }
        else
        {
            if (command.Destination is not { } target) throw Invalid(); ValidatePhotoFolder(target);
            if (command.Action == SynologyPhotoFileAction.Move && command.Space == SynologyPhotoSpace.Shared && target.Space == SynologyPhotoSpace.Personal)
                throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
            if (target.Space == command.Space && (command.Photos.Any(photo => photo.FolderId == target.Id) ||
                command.Folders.Any(folder => folder.ParentId == target.Id || folder.Id == target.Id || FolderContains(folder.Path, target.Path))))
                throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
        }
    }
    private void RequireFileSafety(SynologyPhotoFileCommand command)
    {
        if (command.Action == SynologyPhotoFileAction.Delete && (!CanDeleteOriginals || !FileSafety.ExtendedDeletion &&
            (command.Space != SynologyPhotoSpace.Personal || command.Photos.Count != 1 || command.Folders.Count != 0)))
            throw new SynologyPhotoException(SynologyPhotoFailure.DeletionUnverified);
        if (command.Action == SynologyPhotoFileAction.Move && command.Destination?.Space != command.Space && !FileSafety.CrossSpaceMove ||
            command.Duplicate == SynologyPhotoFileDuplicate.Overwrite && !FileSafety.Overwrite)
            throw new SynologyPhotoException(SynologyPhotoFailure.Unavailable);
    }
    private static SynologyPhoto OriginalFilePhoto(JsonObject entry, Guid profileId, SynologyPhotoSpace space) =>
        new(new(profileId, space, Positive(entry, "id")), Text(entry, "filename"), Number(entry, "filesize"),
            Timestamp(entry, "time"), IndexedTimestamp(entry), Positive(entry, "folder_id"), Text(entry, "type"));
    private async Task<SynologyPhoto> ReadOriginalFilePhotoAsync(SynologyPhoto photo, CancellationToken token)
    {
        RequirePhoto(photo); RequireAccess(photo.Id.Space);
        // 相册贡献者不是原件所有者；原件写入使用来源图库的最小身份读取。
        if (photo.Id.Space == SynologyPhotoSpace.Personal && photo.AlbumContext is { } album && album.OwnerUserId != _currentUserId)
            throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        var entries = List(await ReadAsync("Browse.Item", 5, "get", Parameters(("id", new[] { photo.Id.ItemId })), token, photo.Id.Space).ConfigureAwait(false));
        if (entries.Length != 1 || Positive(entries[0], "id") != photo.Id.ItemId) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
        var current = OriginalFilePhoto(entries[0], ProfileId, photo.Id.Space);
        if (current.SizeBytes < 0) throw Invalid(); return current;
    }
    private async Task<SynologyPhotoFolder[]> PrepareFilesCoreAsync(PhotoFileChangeRecord record, CancellationToken token)
    {
        CheckFileOwner(record); var command = record.Command; ValidateFileCommand(command); RequireFileSafety(command);
        var generation = Volatile.Read(ref _accessGeneration);
        var spaces = new[] { command.Space, command.Destination?.Space ?? command.Space }.Distinct().ToArray();
        await FreshManagementAccessAsync(spaces, token).ConfigureAwait(false);
        _ = Capability("BackgroundTask.File", 1, command.Space); _ = Capability("BackgroundTask.Info", 1, null);
        _ = Capability("Browse.Item", 5, command.Space); _ = Capability("Browse.Folder", 2, command.Space);
        var right = command.Action == SynologyPhotoFileAction.Copy && command.Space == SynologyPhotoSpace.Shared ? PhotoFolderRight.Download : PhotoFolderRight.Manage;
        var parents = new List<SynologyPhotoFolder>();
        foreach (var photo in command.Photos)
        {
            if (photo.AlbumContext is { } sourceAlbum) await CheckAlbumBusyAsync(sourceAlbum.AlbumId, token).ConfigureAwait(false);
            if (!photo.IsSameDeletionTarget(await ReadOriginalFilePhotoAsync(photo, token).ConfigureAwait(false)))
                throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
            if (RecognitionPhotoBusy(photo.Id) || PreviewPhotoBusy(photo.Id) || AlbumPhotoBusy(photo.Id) || _changes.Tasks.Values.Any(task => task.Record.Owner == record.Owner && task.Record.Items.Any(item => item.Original.Id == photo.Id &&
                item.State is not (SynologyPhotoChangeState.Completed or SynologyPhotoChangeState.Cancelled))) ||
                _changes.Folders.Values.Any(task => task.Record.Owner == record.Owner && ActiveFolderChange(task.Record) && task.Record.Edit.Photo?.Id == photo.Id))
                throw new SynologyPhotoException(SynologyPhotoFailure.UploadBusy);
        }
        foreach (var id in command.Photos.Select(photo => photo.FolderId).Concat(command.Folders.Select(folder => folder.ParentId)).Distinct())
        {
            var parent = PhotoFolder(await ReadPhotoFolderAsync(id, command.Space, command.Photos.Any(photo => photo.FolderId == id) ? right : PhotoFolderRight.View, token).ConfigureAwait(false), command.Space);
            parents.Add(parent with { Sort = null });
            if (record.Parents.Length > 0 && !record.Parents.Any(original => SamePhotoFolder(original, parent)))
                throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
            await CheckManagedFolderConflictsAsync(id, command.Space, null, token, record.Id).ConfigureAwait(false);
        }
        foreach (var folder in command.Folders)
        {
            var current = PhotoFolder(await ReadPhotoFolderAsync(folder.Id, folder.Space, right, token).ConfigureAwait(false), folder.Space);
            if (!SamePhotoFolder(folder, current) || folder.Path != ChildFolderPath(parents.Single(parent => parent.Id == folder.ParentId).Path, folder.Name))
                throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
            await CheckManagedFolderConflictsAsync(folder.Id, folder.Space, null, token, record.Id).ConfigureAwait(false);
            await CheckFolderContentsBusyAsync(folder, record.Owner, token).ConfigureAwait(false);
        }
        if (command.Destination is { } target)
        {
            var current = PhotoFolder(await ReadPhotoFolderAsync(target.Id, target.Space, PhotoFolderRight.Upload, token).ConfigureAwait(false), target.Space);
            if (!SamePhotoFolder(target, current)) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
            await CheckManagedFolderConflictsAsync(target.Id, target.Space, null, token, record.Id).ConfigureAwait(false);
            await CheckFileDestinationBusyAsync(record, token).ConfigureAwait(false);
        }
        CheckFileChangesConflict(record with { Parents = parents.ToArray() });
        RequireGeneration(generation, token); CheckFileOwner(record); return parents.ToArray();
    }
    private async Task CheckFileDestinationBusyAsync(PhotoFileChangeRecord record, CancellationToken token)
    {
        var command = record.Command; var target = command.Destination!;
        var names = command.Photos.Select(photo => photo.Filename).Concat(command.Folders.Select(folder => folder.Name)).ToHashSet(StringComparer.Ordinal);
        foreach (var name in names) await CheckManagedFolderConflictsAsync(target.Id, target.Space, name, token, record.Id).ConfigureAwait(false);
        if (command.Duplicate == SynologyPhotoFileDuplicate.Overwrite &&
            _changes.Tasks.Values.Where(task => task.Record.Owner == record.Owner).SelectMany(task => task.Record.Items).Any(item =>
                item.State is not (SynologyPhotoChangeState.Completed or SynologyPhotoChangeState.Cancelled) && item.Original.Id.Space == target.Space &&
                item.Original.FolderId == target.Id && names.Contains(item.Original.Filename))) throw new SynologyPhotoException(SynologyPhotoFailure.UploadBusy);
        if (_uploadStore is null) return; await LoadUploadsAsync().ConfigureAwait(false);
        if (_uploads.Tasks.Values.Where(task => task.Record.Owner == record.Owner && task.Record.Target.Space == target.Space && !task.Record.Target.DirectToAlbum)
            .Any(task => task.Record.Items.Any(item => item.State is not (SynologyPhotoUploadState.Completed or SynologyPhotoUploadState.Skipped or SynologyPhotoUploadState.Cancelled) &&
                (item.FolderId == target.Id && names.Contains(item.File.Name) || item.FolderParent == target.Id && item.FolderName is { } name && names.Contains(name)))))
            throw new SynologyPhotoException(SynologyPhotoFailure.UploadBusy);
    }
    private async Task CheckFolderContentsBusyAsync(SynologyPhotoFolder folder, string owner, CancellationToken token, Guid exceptFolderSharing = default)
    {
        await CheckRecognitionFolderLocksAsync(folder, token, true).ConfigureAwait(false);
        CheckFolderSharingLocks(folder, exceptFolderSharing, true);
        await CheckRequestFolderLocksAsync(folder, token).ConfigureAwait(false);
        var metadata = _changes.Tasks.Values.Where(task => task.Record.Owner == owner).SelectMany(task => task.Record.Items)
            .Where(item => item.Original.Id.Space == folder.Space && item.State is not (SynologyPhotoChangeState.Completed or SynologyPhotoChangeState.Cancelled));
        var covers = _changes.Folders.Values.Where(task => task.Record.Owner == owner && ActiveFolderChange(task.Record));
        if (covers.Any(task => task.Record.Edit.Folder.Space == folder.Space &&
            (FolderContains(folder.Path, task.Record.Edit.Folder.Path) || FolderRenameContains(task.Record, folder.Path))))
            throw new SynologyPhotoException(SynologyPhotoFailure.UploadBusy);
        foreach (var id in metadata.Select(item => item.Original.FolderId).Concat(covers.Where(task => task.Record.Edit.Photo?.Id.Space == folder.Space)
            .Select(task => task.Record.Edit.Photo!.FolderId)).Concat(_changes.Albums.Values.Where(task => task.Record.Owner == owner && ActiveAlbumChange(task.Record))
                .SelectMany(task => task.Record.Edit.Photos).Where(photo => photo.Id.Space == folder.Space).Select(photo => photo.FolderId)).Distinct())
        {
            var current = PhotoFolder(await ReadPhotoFolderAsync(id, folder.Space, PhotoFolderRight.View, token).ConfigureAwait(false), folder.Space);
            if (FolderContains(folder.Path, current.Path)) throw new SynologyPhotoException(SynologyPhotoFailure.UploadBusy);
        }
        if (_uploadStore is null) return; await LoadUploadsAsync().ConfigureAwait(false);
        foreach (var upload in _uploads.Tasks.Values.Where(task => task.Record.Owner == owner && task.Record.Target.Space == folder.Space &&
            !task.Record.Target.DirectToAlbum && task.Record.Items.Any(item => item.State is not (SynologyPhotoUploadState.Completed or SynologyPhotoUploadState.Skipped or SynologyPhotoUploadState.Cancelled))))
        {
            if ((upload.Record.Root?.Id ?? upload.Record.Target.FolderId) is { } rootId)
            {
                var target = PhotoFolder(await ReadPhotoFolderAsync(rootId, folder.Space, PhotoFolderRight.View, token).ConfigureAwait(false), folder.Space);
                if (FolderContains(folder.Path, target.Path)) throw new SynologyPhotoException(SynologyPhotoFailure.UploadBusy);
            }
        }
    }
    private static IEnumerable<SynologyPhotoFolder> FileProtectedFolders(PhotoFileChangeRecord record)
    {
        foreach (var folder in record.Command.Folders)
        {
            yield return folder;
            if (record.Command.Destination is { } destination)
                yield return folder with { Space = destination.Space, Id = 0, Path = ChildFolderPath(destination.Path, folder.Name), ParentId = destination.Id };
        }
    }
    private void CheckFileChangesConflict(PhotoFileChangeRecord record)
    {
        var command = record.Command;
        foreach (var other in _changes.Files.Values.Select(task => task.Record).Where(other => other.Id != record.Id && other.Owner == record.Owner && ActiveFileChange(other)))
        {
            if (command.Photos.Any(photo => other.Command.Photos.Any(existing => existing.Id == photo.Id))) throw new SynologyPhotoException(SynologyPhotoFailure.UploadBusy);
            var currentLocations = record.Parents.Concat(command.Folders).Concat(command.Destination is { } target ? [target] : []);
            var otherLocations = other.Parents.Concat(other.Command.Folders).Concat(other.Command.Destination is { } otherTarget ? [otherTarget] : []);
            if (FileProtectedFolders(other).Any(folder => currentLocations.Any(location => location.Space == folder.Space && FolderContains(folder.Path, location.Path))) ||
                FileProtectedFolders(record).Any(folder => otherLocations.Any(location => location.Space == folder.Space && FolderContains(folder.Path, location.Path))) ||
                command.Destination is { } destination && other.Command.Destination is { } previous && SamePhotoFolder(destination, previous) &&
                    command.Photos.Select(photo => photo.Filename).Concat(command.Folders.Select(folder => folder.Name)).Intersect(
                        other.Command.Photos.Select(photo => photo.Filename).Concat(other.Command.Folders.Select(folder => folder.Name)), StringComparer.Ordinal).Any())
                throw new SynologyPhotoException(SynologyPhotoFailure.UploadBusy);
        }
    }
    private bool FilePhotoBusy(SynologyPhotoIdentity id) => _changes.Files.Values.Any(task => task.Record.Owner == UploadOwner() && ActiveFileChange(task.Record) &&
        task.Record.Command.Photos.Any(photo => photo.Id == id));
    private async Task CheckFileFolderConflictsAsync(long id, SynologyPhotoSpace space, string? childName, Guid except, CancellationToken token, bool includeChildren = false)
    {
        var records = _changes.Files.Values.Select(task => task.Record).Where(record => record.Id != except && record.Owner == UploadOwner() && ActiveFileChange(record)).ToArray();
        if (records.Length == 0) return;
        var current = PhotoFolder(await ReadPhotoFolderAsync(id, space, PhotoFolderRight.View, token).ConfigureAwait(false), space);
        if (records.Any(record => FileProtectedFolders(record).Any(folder => folder.Space == space && (folder.Id == id || FolderContains(folder.Path, current.Path) ||
            includeChildren && FolderContains(current.Path, folder.Path))) ||
            includeChildren && record.Parents.Concat(record.Command.Destination is { } target ? [target] : []).Any(parent => parent.Space == space && FolderContains(current.Path, parent.Path)) ||
            childName is not null && record.Command.Destination is { } destination && destination.Space == space && destination.Id == id &&
                record.Command.Photos.Select(photo => photo.Filename).Concat(record.Command.Folders.Select(folder => folder.Name)).Contains(childName, StringComparer.Ordinal)))
            throw new SynologyPhotoException(SynologyPhotoFailure.UploadBusy);
    }
}
