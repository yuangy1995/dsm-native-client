using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

/// <summary>
/// 公开 File Station API 的只读文件系统照片适配，不调用 Synology Photos 私有接口。
/// </summary>
public sealed partial class DsmRepository
{
    private static readonly HashSet<string> ImageExtensions = new(
        ["jpg", "jpeg", "png", "gif", "bmp", "webp", "heic", "heif", "tif", "tiff"],
        StringComparer.OrdinalIgnoreCase);

    private static readonly HashSet<string> VideoExtensions = new(
        ["mp4", "mov", "m4v", "avi", "mkv", "webm"],
        StringComparer.OrdinalIgnoreCase);

    public async Task<IReadOnlyList<PhotoSpace>> DiscoverSpacesAsync(
        CancellationToken cancellationToken = default)
    {
        EnsurePhotoProfile();
        var spaces = new List<PhotoSpace>(2);
        try
        {
            _ = await LoadPhotoSourcePageAsync(
                PhotoSpace.Personal.RootPath,
                0,
                1,
                cancellationToken).ConfigureAwait(false);
            spaces.Add(PhotoSpace.Personal);
        }
        catch (DsmException error) when (SpaceMayBeUnavailable(error))
        {
            // 个人照片目录未启用或当前账号不可见时，继续独立探测共享空间。
        }

        var shares = await CallAsync(
            "SYNO.FileStation.List",
            "list_share",
            new Dictionary<string, string>
            {
                ["offset"] = "0",
                ["limit"] = "500",
                ["sort_by"] = "name",
                ["sort_direction"] = "asc",
            },
            cancellationToken).ConfigureAwait(false);
        var sharePage = ParsePhotoSourcePage(shares, "shares", 0);
        if (sharePage.Items.Any(item =>
                StrictBoolean(item, "isdir") == true &&
                string.Equals(
                    StrictString(item, "path"),
                    PhotoSpace.Shared.RootPath,
                    StringComparison.OrdinalIgnoreCase)))
        {
            spaces.Add(PhotoSpace.Shared);
        }
        return spaces;
    }

    public async Task<PhotoPage> ListFolderAsync(
        PhotoSpace space,
        string path,
        int offset,
        int limit,
        CancellationToken cancellationToken = default)
    {
        EnsurePhotoProfile();
        ArgumentNullException.ThrowIfNull(space);
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        ArgumentOutOfRangeException.ThrowIfNegative(offset);
        ArgumentOutOfRangeException.ThrowIfLessThan(limit, 1);
        var rootPath = ResolvePhotoSpaceRoot(space);
        if (!ContainsPhotoPath(path, rootPath))
        {
            throw new ArgumentException(
                "The requested folder is outside the selected photo space.",
                nameof(path));
        }

        var source = await LoadPhotoSourcePageAsync(
            path,
            offset,
            limit,
            cancellationToken).ConfigureAwait(false);
        var items = source.Items
            .Select(item => ParsePhotoItem(item, rootPath, path))
            .OfType<PhotoItem>()
            .ToArray();
        var nextOffset = checked(source.Offset + source.Items.Count);
        var hasMore = nextOffset > source.Offset && nextOffset < source.Total;
        return new PhotoPage(
            _profile.Id,
            path,
            items,
            source.Offset,
            nextOffset,
            source.Total,
            hasMore);
    }

    public async Task<PhotoTimelineSnapshot> LoadTimelineAsync(
        PhotoSpace space,
        PhotoTimelineLimits? limits = null,
        CancellationToken cancellationToken = default)
    {
        EnsurePhotoProfile();
        ArgumentNullException.ThrowIfNull(space);
        var effectiveLimits = limits ?? PhotoTimelineLimits.Default;
        effectiveLimits.Validate();
        var rootPath = ResolvePhotoSpaceRoot(space);
        var pending = new Queue<string>();
        var visited = new HashSet<string>(StringComparer.Ordinal) { rootPath };
        var mediaByPath = new Dictionary<string, PhotoItem>(StringComparer.Ordinal);
        pending.Enqueue(rootPath);
        var scannedFolders = 0;
        var skippedFolders = 0;
        var sourceItems = 0;
        var truncated = false;

        while (pending.Count > 0 && !truncated)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (scannedFolders >= effectiveLimits.MaximumFolders)
            {
                truncated = true;
                break;
            }

            var folderPath = pending.Dequeue();
            // 硬上限按实际尝试的目录计数；权限失败的子目录同样消耗预算。
            scannedFolders++;
            var stagedMediaByPath = new Dictionary<string, PhotoItem>(StringComparer.Ordinal);
            var stagedSubfolders = new List<string>();
            var stagedSubfolderPaths = new HashSet<string>(StringComparer.Ordinal);
            var completedFolder = false;
            try
            {
                var offset = 0;
                int? expectedTotal = null;
                while (true)
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    var page = await LoadPhotoSourcePageAsync(
                        folderPath,
                        offset,
                        effectiveLimits.PageSize,
                        cancellationToken).ConfigureAwait(false);
                    cancellationToken.ThrowIfCancellationRequested();
                    if (expectedTotal is { } total && total != page.Total)
                    {
                        throw new InvalidDataException("photo.timeline.total-changed");
                    }
                    expectedTotal ??= page.Total;

                    var pageItemsProcessed = 0;
                    foreach (var source in page.Items)
                    {
                        if (sourceItems >= effectiveLimits.MaximumSourceItems)
                        {
                            truncated = true;
                            break;
                        }
                        sourceItems++;
                        pageItemsProcessed++;
                        var item = ParsePhotoItem(source, rootPath, folderPath);
                        if (item is null)
                        {
                            continue;
                        }
                        if (item.Kind == PhotoItemKind.Folder)
                        {
                            if (!visited.Contains(item.Path) && stagedSubfolderPaths.Add(item.Path))
                            {
                                stagedSubfolders.Add(item.Path);
                            }
                            continue;
                        }
                        if (!mediaByPath.ContainsKey(item.Path))
                        {
                            stagedMediaByPath.TryAdd(item.Path, item);
                        }
                        if (mediaByPath.Count + stagedMediaByPath.Count >=
                            effectiveLimits.MaximumMediaItems)
                        {
                            truncated = pageItemsProcessed < page.Items.Count ||
                                page.NextOffset < page.Total || pending.Count > 0 ||
                                stagedSubfolders.Count > 0;
                            break;
                        }
                    }
                    if (truncated || mediaByPath.Count + stagedMediaByPath.Count >=
                        effectiveLimits.MaximumMediaItems)
                    {
                        truncated = truncated || page.NextOffset < page.Total ||
                            pending.Count > 0 || stagedSubfolders.Count > 0;
                        break;
                    }
                    if (sourceItems >= effectiveLimits.MaximumSourceItems &&
                        (page.NextOffset < page.Total || pending.Count > 0))
                    {
                        truncated = true;
                        break;
                    }
                    if (page.NextOffset >= page.Total)
                    {
                        completedFolder = true;
                        break;
                    }
                    offset = page.NextOffset;
                }

                // 主动预算截断保留已扫描媒体；只有完整目录才能扩展其子目录。
                foreach (var (path, item) in stagedMediaByPath)
                {
                    mediaByPath.TryAdd(path, item);
                }
                if (completedFolder)
                {
                    foreach (var subfolder in stagedSubfolders)
                    {
                        if (visited.Add(subfolder))
                        {
                            pending.Enqueue(subfolder);
                        }
                    }
                }
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (Exception error) when (
                !string.Equals(folderPath, rootPath, StringComparison.Ordinal) &&
                error is DsmException or InvalidDataException)
            {
                skippedFolders++;
            }
        }

        if (pending.Count > 0)
        {
            truncated = true;
        }
        var items = mediaByPath.Values
            .OrderByDescending(item => (item.CreatedAt ?? item.ModifiedAt).HasValue)
            .ThenByDescending(item => item.CreatedAt ?? item.ModifiedAt)
            .ThenBy(item => item.Path, StringComparer.Ordinal)
            .ToArray();
        return new PhotoTimelineSnapshot(
            _profile.Id,
            space.Id,
            items,
            scannedFolders,
            skippedFolders,
            sourceItems,
            truncated
                ? PhotoTimelineCompletion.Truncated
                : PhotoTimelineCompletion.Complete);
    }

    public async Task<PhotoThumbnail> GetThumbnailAsync(
        PhotoItem item,
        PhotoThumbnailSize size,
        CancellationToken cancellationToken = default)
    {
        EnsurePhotoProfile();
        ArgumentNullException.ThrowIfNull(item);
        if (item.ProfileId != _profile.Id)
        {
            throw new ArgumentException(
                "The photo belongs to a different NAS profile.",
                nameof(item));
        }
        if (item.Kind != PhotoItemKind.Image)
        {
            throw new ArgumentException(
                "Only image items support File Station thumbnails.",
                nameof(item));
        }
        if (!ContainsPhotoPath(item.Path, PhotoSpace.Personal.RootPath) &&
            !ContainsPhotoPath(item.Path, PhotoSpace.Shared.RootPath))
        {
            throw new ArgumentException(
                "The photo is outside the supported photo spaces.",
                nameof(item));
        }

        var capability = Required("SYNO.FileStation.Thumb");
        if (capability.MinVersion > 2 || capability.MaxVersion < 2)
        {
            throw new DsmException(
                UserText.Key("WinShared189ee06b7da78f3f"),
                UserText.Key("WinSharedb5641013fbf13d8b"),
                103);
        }
        var response = await _api.ReadBinaryAsync(
            _profile,
            _session,
            capability,
            "get",
            new Dictionary<string, string>
            {
                ["path"] = item.Path,
                ["size"] = ThumbnailSizeValue(size),
                ["rotate"] = "0",
            },
            "image/",
            PhotoThumbnail.MaximumBytes,
            cancellationToken).ConfigureAwait(false);
        return new PhotoThumbnail(response.Bytes, response.MediaType);
    }

    private async Task<PhotoSourcePage> LoadPhotoSourcePageAsync(
        string path,
        int offset,
        int limit,
        CancellationToken cancellationToken)
    {
        var requestedLimit = Math.Min(limit, 500);
        var data = await CallAsync(
            "SYNO.FileStation.List",
            "list",
            new Dictionary<string, string>
            {
                ["folder_path"] = path,
                ["offset"] = offset.ToString(System.Globalization.CultureInfo.InvariantCulture),
                ["limit"] = requestedLimit.ToString(
                    System.Globalization.CultureInfo.InvariantCulture),
                ["sort_by"] = "name",
                ["sort_direction"] = "asc",
                ["additional"] = "[\"size\",\"time\"]",
            },
            cancellationToken).ConfigureAwait(false);
        return ParsePhotoSourcePage(data, "files", offset);
    }

    private PhotoItem? ParsePhotoItem(
        JsonObject source,
        string rootPath,
        string folderPath)
    {
        var path = StrictString(source, "path")
            ?? throw new InvalidDataException("photo.invalid-item-path");
        var name = StrictString(source, "name")
            ?? throw new InvalidDataException("photo.invalid-item-name");
        var isDirectory = StrictBoolean(source, "isdir")
            ?? throw new InvalidDataException("photo.invalid-item-kind");
        if (!StrictAbsolutePath(path) ||
            !ContainsPhotoPath(path, rootPath) ||
            !IsDirectChild(path, folderPath))
        {
            throw new InvalidDataException("photo.invalid-item-path");
        }
        if (name.StartsWith('@') || string.Equals(name, "#recycle", StringComparison.Ordinal))
        {
            return null;
        }
        var extension = isDirectory
            ? null
            : System.IO.Path.GetExtension(path).TrimStart('.').ToLowerInvariant();
        var kind = isDirectory
            ? PhotoItemKind.Folder
            : ImageExtensions.Contains(extension ?? string.Empty)
                ? PhotoItemKind.Image
                : VideoExtensions.Contains(extension ?? string.Empty)
                    ? PhotoItemKind.Video
                    : (PhotoItemKind?)null;
        if (kind is null)
        {
            return null;
        }

        var additional = OptionalObject(source, "additional");
        var time = OptionalObject(additional, "time");
        var rawSize = StrictOptionalInteger(source, "size") ??
            StrictOptionalInteger(additional, "size");
        if (!isDirectory && rawSize is < 0)
        {
            throw new InvalidDataException("photo.invalid-size-field");
        }
        var size = isDirectory ? null : rawSize;
        return new PhotoItem(
            _profile.Id,
            $"{_profile.Id:N}:{path}",
            name,
            path,
            kind.Value,
            size,
            StrictOptionalEpoch(time, "crtime") ?? StrictOptionalEpoch(source, "crtime"),
            StrictOptionalEpoch(time, "mtime") ?? StrictOptionalEpoch(source, "mtime"),
            string.IsNullOrEmpty(extension) ? null : extension,
            null);
    }

    private static string ResolvePhotoSpaceRoot(PhotoSpace space) => space switch
    {
        { Id: PhotoSpaceIds.Personal, RootPath: "/home/Photos" } => PhotoSpace.Personal.RootPath,
        { Id: PhotoSpaceIds.Shared, RootPath: "/photo" } => PhotoSpace.Shared.RootPath,
        _ => throw new ArgumentException("The photo space is not recognized.", nameof(space)),
    };

    private static bool ContainsPhotoPath(string path, string rootPath)
    {
        var candidate = path.Split('/', StringSplitOptions.RemoveEmptyEntries);
        var root = rootPath.Split('/', StringSplitOptions.RemoveEmptyEntries);
        return candidate.Length >= root.Length &&
               !candidate.Any(segment => segment is "." or "..") &&
               candidate.Take(root.Length).SequenceEqual(root, StringComparer.Ordinal);
    }

    private static PhotoSourcePage ParsePhotoSourcePage(
        JsonObject data,
        string root,
        int requestedOffset)
    {
        var offset = StrictInteger(data, "offset")
            ?? throw new InvalidDataException("photo.invalid-page-offset");
        var total = StrictInteger(data, "total")
            ?? throw new InvalidDataException("photo.invalid-page-total");
        if (offset != requestedOffset || offset < 0 || total < 0 || offset > total ||
            data[root] is not JsonArray values)
        {
            throw new InvalidDataException("photo.invalid-page");
        }
        var items = new List<JsonObject>(values.Count);
        foreach (var value in values)
        {
            if (value is not JsonObject item)
            {
                throw new InvalidDataException("photo.invalid-page-item");
            }
            items.Add(item);
        }
        if (items.Count > total - offset || items.Count == 0 && offset < total)
        {
            throw new InvalidDataException("photo.page-did-not-advance");
        }
        return new PhotoSourcePage(items, total, offset);
    }

    private static int? StrictInteger(JsonObject? source, string key) =>
        source?[key] is JsonValue value && value.TryGetValue<int>(out var result)
            ? result
            : null;

    private static long? StrictOptionalInteger(JsonObject? source, string key)
    {
        if (source is null || !source.ContainsKey(key) || source[key] is null)
        {
            return null;
        }
        if (source[key] is not JsonValue value)
        {
            throw new InvalidDataException("photo.invalid-integer-field");
        }
        if (value.TryGetValue<long>(out var longValue))
        {
            return longValue;
        }
        if (value.TryGetValue<int>(out var intValue))
        {
            return intValue;
        }
        throw new InvalidDataException("photo.invalid-integer-field");
    }

    private static bool? StrictBoolean(JsonObject source, string key) =>
        source[key] is JsonValue value && value.TryGetValue<bool>(out var result)
            ? result
            : null;

    private static string? StrictString(JsonObject source, string key) =>
        source[key] is JsonValue value && value.TryGetValue<string>(out var result) &&
        !string.IsNullOrEmpty(result)
            ? result
            : null;

    private static JsonObject? OptionalObject(JsonObject? source, string key)
    {
        if (source is null || !source.ContainsKey(key) || source[key] is null)
        {
            return null;
        }
        return source[key] as JsonObject
            ?? throw new InvalidDataException("photo.invalid-object-field");
    }

    private static DateTimeOffset? StrictOptionalEpoch(JsonObject? source, string key)
    {
        var epoch = StrictOptionalInteger(source, key);
        if (epoch is null)
        {
            return null;
        }
        try
        {
            return epoch > 10_000_000_000
                ? DateTimeOffset.FromUnixTimeMilliseconds(epoch.Value)
                : DateTimeOffset.FromUnixTimeSeconds(epoch.Value);
        }
        catch (ArgumentOutOfRangeException)
        {
            throw new InvalidDataException("photo.invalid-date-field");
        }
    }

    private static bool StrictAbsolutePath(string path) =>
        path.Length > 1 &&
        path.StartsWith('/') &&
        !path.EndsWith('/') &&
        !path.Contains("//", StringComparison.Ordinal) &&
        !path.Contains('\\') &&
        !path.Split('/').Any(segment => segment is "." or "..");

    private static bool IsDirectChild(string path, string folderPath)
    {
        var candidate = path.Split('/', StringSplitOptions.RemoveEmptyEntries);
        var folder = folderPath.Split('/', StringSplitOptions.RemoveEmptyEntries);
        return candidate.Length == folder.Length + 1 &&
               !candidate.Any(segment => segment is "." or "..") &&
               candidate.Take(folder.Length).SequenceEqual(folder, StringComparer.Ordinal);
    }

    private static bool SpaceMayBeUnavailable(DsmException error) =>
        !error.AuthenticationFailure && error.Code is 105 or 408;

    private void EnsurePhotoProfile()
    {
        if (_session.ProfileId != _profile.Id)
        {
            throw new InvalidOperationException(
                "The DSM session belongs to a different NAS profile.");
        }
    }

    private static string ThumbnailSizeValue(PhotoThumbnailSize size) => size switch
    {
        PhotoThumbnailSize.Small => "small",
        PhotoThumbnailSize.Medium => "medium",
        PhotoThumbnailSize.Large => "large",
        _ => throw new ArgumentOutOfRangeException(nameof(size)),
    };

    private sealed record PhotoSourcePage(
        IReadOnlyList<JsonObject> Items,
        int Total,
        int Offset)
    {
        public int NextOffset => checked(Offset + Items.Count);
    }
}
