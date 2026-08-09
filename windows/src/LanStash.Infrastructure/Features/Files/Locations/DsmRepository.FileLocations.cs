using System.Collections.Concurrent;
using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private const int LocationApiVersion = 2;
    private const int FavoritePageSize = 500;
    private const int FavoriteLimit = 5_000;
    private const int LocationSharePageSize = 200;
    private const int ShareSourceLimit = 500;
    private const int RecycleProbeLimit = 500;
    private const int RecycleProbeConcurrency = 4;
    private const int RemotePageSize = 500;
    private const int RemoteProtocolLimit = 5_000;
    private const int RemoteResultLimit = 5_000;

    FileLocationsAvailability IFileLocationsRepository.Availability => LocationAvailability;

    Task<FileLocationsSnapshot> IFileLocationsRepository.LoadSnapshotAsync(
        CancellationToken cancellationToken) =>
        LoadFileLocationsSnapshotAsync(cancellationToken);

    private FileLocationsAvailability LocationAvailability => new(
        HasFixedVersionCapability("SYNO.FileStation.Favorite"),
        HasFixedVersionCapability("SYNO.FileStation.List"),
        HasFixedVersionCapability("SYNO.FileStation.Info") &&
            HasFixedVersionCapability("SYNO.FileStation.VirtualFolder"));

    private async Task<FileLocationsSnapshot> LoadFileLocationsSnapshotAsync(
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var availability = LocationAvailability;
        var favoritesTask = availability.Favorites
            ? LoadSectionAsync(
                LoadFavoriteLocationsAsync,
                () => FailedFavorites("file.locations.favorite.load_failed"),
                cancellationToken)
            : Task.FromResult(UnavailableFavorites());
        var recycleTask = availability.RecycleBins
            ? LoadSectionAsync(
                DiscoverRecycleLocationsAsync,
                () => FailedRecycleBins("file.locations.recycle.load_failed"),
                cancellationToken)
            : Task.FromResult(UnavailableRecycleBins());
        var remoteTask = availability.RemoteLocations
            ? LoadSectionAsync(
                LoadRemoteLocationsAsync,
                () => FailedRemoteLocations("file.locations.remote.load_failed"),
                cancellationToken)
            : Task.FromResult(UnavailableRemoteLocations());
        await Task.WhenAll(favoritesTask, recycleTask, remoteTask).ConfigureAwait(false);
        cancellationToken.ThrowIfCancellationRequested();
        return new FileLocationsSnapshot(
            ProfileId,
            availability,
            await favoritesTask.ConfigureAwait(false),
            await recycleTask.ConfigureAwait(false),
            await remoteTask.ConfigureAwait(false));
    }

    private static async Task<T> LoadSectionAsync<T>(
        Func<CancellationToken, Task<T>> loader,
        Func<T> failed,
        CancellationToken cancellationToken)
    {
        try
        {
            return await loader(cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (DsmException error) when (IsAuthenticationOrSessionFailure(error))
        {
            throw;
        }
        catch (DsmException)
        {
            return failed();
        }
        catch (DsmReadContractUnsupportedException)
        {
            return failed();
        }
        catch (JsonException)
        {
            return failed();
        }
        catch (InvalidDataException)
        {
            return failed();
        }
        catch (IOException)
        {
            return failed();
        }
    }

    private bool HasFixedVersionCapability(string name) =>
        _capabilities.TryGetValue(name, out var capability) &&
        string.Equals(capability.Name, name, StringComparison.Ordinal) &&
        capability.MinVersion <= LocationApiVersion &&
        capability.MaxVersion >= LocationApiVersion &&
        string.Equals(capability.RequestFormat, "FORM", StringComparison.OrdinalIgnoreCase);

    private Task<JsonObject> CallLocationReadAsync(
        string apiName,
        string method,
        IReadOnlyDictionary<string, string>? parameters,
        CancellationToken cancellationToken)
    {
        if (!HasFixedVersionCapability(apiName) ||
            !_capabilities.TryGetValue(apiName, out var capability) ||
            !string.Equals(capability.Name, apiName, StringComparison.Ordinal))
        {
            throw new NotSupportedException("The required file-location API is unavailable.");
        }
        return _api.CallReadJsonObjectAsync(
            _profile,
            _session,
            capability,
            LocationApiVersion,
            method,
            parameters,
            cancellationToken);
    }

    private async Task<FileFavoriteSnapshot> LoadFavoriteLocationsAsync(
        CancellationToken cancellationToken)
    {
        var rawOffset = 0;
        int? expectedTotal = null;
        bool? metadataMode = null;
        var sourceTotal = 0;
        var truncated = false;
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var ordered = new List<FileFavoriteLocation>();

        while (rawOffset < FavoriteLimit)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var requestLimit = Math.Min(FavoritePageSize, FavoriteLimit - rawOffset);
            var data = await CallLocationReadAsync(
                "SYNO.FileStation.Favorite",
                "list",
                PageParameters(rawOffset, requestLimit),
                cancellationToken).ConfigureAwait(false);
            var favorites = RequiredArray(data, "favorites");
            if (favorites.Count > requestLimit)
            {
                throw InvalidLocationsResponse("favorite.page_limit");
            }
            var hasOffset = data.ContainsKey("offset");
            var hasTotal = data.ContainsKey("total");
            if (hasOffset != hasTotal || metadataMode is { } mode && mode != hasOffset)
            {
                throw InvalidLocationsResponse("favorite.pagination_mode");
            }
            metadataMode ??= hasOffset;
            if (hasOffset)
            {
                var responseOffset = LocationRequiredNonNegativeInt(data, "offset");
                var responseTotal = LocationRequiredNonNegativeInt(data, "total");
                if (responseOffset != rawOffset || responseOffset > responseTotal ||
                    favorites.Count > responseTotal - responseOffset ||
                    expectedTotal is { } stable && stable != responseTotal)
                {
                    throw InvalidLocationsResponse("favorite.pagination_bounds");
                }
                expectedTotal ??= responseTotal;
                if (favorites.Count == 0 && rawOffset < Math.Min(responseTotal, FavoriteLimit))
                {
                    throw InvalidLocationsResponse("favorite.zero_progress");
                }
            }

            foreach (var node in favorites)
            {
                var item = RequiredObject(node, "favorite.item");
                var path = CanonicalDirectoryPath(LocationRequiredString(item, "path"));
                var suppliedName = LocationOptionalString(item, "name")?.Trim();
                var name = string.IsNullOrEmpty(suppliedName)
                    ? path[(path.LastIndexOf('/') + 1)..]
                    : suppliedName;
                ValidateLocationName(name);
                if (seen.Add(path))
                {
                    ordered.Add(new FileFavoriteLocation(ProfileId, name, path));
                }
            }

            var nextOffset = checked(rawOffset + favorites.Count);
            sourceTotal = nextOffset;
            if (expectedTotal is { } total)
            {
                var boundedTotal = Math.Min(total, FavoriteLimit);
                if (nextOffset > boundedTotal)
                {
                    throw InvalidLocationsResponse("favorite.pagination_overrun");
                }
                if (nextOffset >= boundedTotal)
                {
                    sourceTotal = total;
                    truncated = total > FavoriteLimit;
                    break;
                }
            }
            else
            {
                if (favorites.Count < requestLimit)
                {
                    break;
                }
                if (nextOffset == FavoriteLimit)
                {
                    truncated = true;
                    break;
                }
                if (favorites.Count == 0)
                {
                    break;
                }
            }
            rawOffset = nextOffset;
        }

        var items = ordered
            .Take(FavoriteLimit)
            .ToArray();
        return new FileFavoriteSnapshot(
            items,
            items.Length,
            sourceTotal,
            truncated ? FileLocationCompletion.Truncated : FileLocationCompletion.Complete,
            FileLocationSectionStatus.Available);
    }

    private async Task<FileRecycleSnapshot> DiscoverRecycleLocationsAsync(
        CancellationToken cancellationToken)
    {
        var shares = new Dictionary<string, ShareCandidate>(StringComparer.Ordinal);
        var rawOffset = 0;
        int? expectedTotal = null;
        var shareListTruncated = false;
        while (rawOffset < ShareSourceLimit)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var requestLimit = Math.Min(LocationSharePageSize, ShareSourceLimit - rawOffset);
            var parameters = PageParameters(rawOffset, requestLimit);
            parameters["sort_by"] = "name";
            parameters["sort_direction"] = "asc";
            parameters["additional"] = "[\"mount_point_type\"]";
            var data = await CallLocationReadAsync(
                "SYNO.FileStation.List",
                "list_share",
                parameters,
                cancellationToken).ConfigureAwait(false);
            var page = RequiredArray(data, "shares");
            if (page.Count > requestLimit)
            {
                throw InvalidLocationsResponse("recycle.share_page_limit");
            }
            var responseOffset = LocationRequiredNonNegativeInt(data, "offset");
            var total = LocationRequiredNonNegativeInt(data, "total");
            if (responseOffset != rawOffset || responseOffset > total ||
                page.Count > total - responseOffset ||
                expectedTotal is { } stable && stable != total)
            {
                throw InvalidLocationsResponse("recycle.share_pagination");
            }
            expectedTotal ??= total;
            if (page.Count == 0 && rawOffset < Math.Min(total, ShareSourceLimit))
            {
                throw InvalidLocationsResponse("recycle.share_zero_progress");
            }
            foreach (var node in page)
            {
                var item = RequiredObject(node, "recycle.share_item");
                var path = CanonicalDirectoryPath(LocationRequiredString(item, "path"));
                var name = LocationRequiredString(item, "name").Trim();
                ValidateLocationName(name);
                if (!RequiredNativeBool(item, "isdir"))
                {
                    throw InvalidLocationsResponse("recycle.share_not_directory");
                }
                var mountType = OptionalMountPointType(item);
                if (IsLocalShareMountType(mountType))
                {
                    shares.TryAdd(path, new ShareCandidate(name, path));
                }
            }
            var nextOffset = checked(rawOffset + page.Count);
            var boundedTotal = Math.Min(total, ShareSourceLimit);
            if (nextOffset > boundedTotal)
            {
                throw InvalidLocationsResponse("recycle.share_overrun");
            }
            if (nextOffset >= boundedTotal)
            {
                shareListTruncated = total > ShareSourceLimit;
                break;
            }
            rawOffset = nextOffset;
        }

        var ordered = shares.Values
            .OrderBy(item => item.Name, StringComparer.OrdinalIgnoreCase)
            .ThenBy(item => item.Path, StringComparer.Ordinal)
            .ToArray();
        var selected = ordered.Take(RecycleProbeLimit).ToArray();
        var results = new ConcurrentBag<RecycleProbeResult>();
        await Parallel.ForEachAsync(
            selected,
            new ParallelOptions
            {
                MaxDegreeOfParallelism = RecycleProbeConcurrency,
                CancellationToken = cancellationToken,
            },
            async (share, token) => results.Add(await ProbeRecycleAsync(share, token).ConfigureAwait(false)))
            .ConfigureAwait(false);

        var accessible = results
            .Where(result => result.Status == RecycleProbeStatus.Accessible)
            .Select(result => new FileRecycleLocation(
                ProfileId,
                result.Share.Name,
                result.Share.Path,
                RecyclePath(result.Share.Path)))
            .OrderBy(item => item.ShareName, StringComparer.OrdinalIgnoreCase)
            .ThenBy(item => item.SharePath, StringComparer.Ordinal)
            .ToArray();
        var notFound = results.Count(result => result.Status == RecycleProbeStatus.NotFound);
        var permissionDenied = results.Count(result => result.Status == RecycleProbeStatus.PermissionDenied);
        var truncated = shareListTruncated || ordered.Length > RecycleProbeLimit;
        return new FileRecycleSnapshot(
            accessible,
            selected.Length,
            notFound,
            permissionDenied,
            permissionDenied > 0,
            truncated ? FileLocationCompletion.Truncated : FileLocationCompletion.Complete,
            FileLocationSectionStatus.Available);
    }

    private async Task<RecycleProbeResult> ProbeRecycleAsync(
        ShareCandidate share,
        CancellationToken cancellationToken)
    {
        try
        {
            var parameters = PageParameters(0, 1);
            parameters["folder_path"] = RecyclePath(share.Path);
            parameters["sort_by"] = "name";
            parameters["sort_direction"] = "asc";
            var data = await CallLocationReadAsync(
                "SYNO.FileStation.List",
                "list",
                parameters,
                cancellationToken).ConfigureAwait(false);
            var files = RequiredArray(data, "files");
            var offset = LocationRequiredNonNegativeInt(data, "offset");
            var total = LocationRequiredNonNegativeInt(data, "total");
            if (offset != 0 || files.Count > 1 || files.Count > total ||
                total > 0 && files.Count == 0)
            {
                throw InvalidLocationsResponse("recycle.probe_shape");
            }
            var recyclePath = RecyclePath(share.Path);
            foreach (var node in files)
            {
                var item = RequiredObject(node, "recycle.probe_item");
                var itemPath = CanonicalDirectoryPath(LocationRequiredString(item, "path"));
                if (!itemPath.StartsWith($"{recyclePath}/", StringComparison.Ordinal))
                {
                    throw InvalidLocationsResponse("recycle.probe_containment");
                }
            }
            return new RecycleProbeResult(share, RecycleProbeStatus.Accessible);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (DsmException error) when (error.Code is 404 or 408 or 900)
        {
            return new RecycleProbeResult(share, RecycleProbeStatus.NotFound);
        }
        catch (DsmException error) when (error.Code == 105)
        {
            return new RecycleProbeResult(share, RecycleProbeStatus.PermissionDenied);
        }
        catch (DsmException error) when (IsAuthenticationOrSessionFailure(error))
        {
            throw;
        }
    }

    private async Task<FileRemoteSnapshot> LoadRemoteLocationsAsync(
        CancellationToken cancellationToken)
    {
        var info = await CallLocationReadAsync(
            "SYNO.FileStation.Info",
            "get",
            parameters: null,
            cancellationToken).ConfigureAwait(false);
        var protocols = ParseSupportedProtocols(info);
        if (protocols.Count == 0)
        {
            return AvailableEmptyRemoteLocations();
        }

        var staged = new List<FileRemoteLocation>();
        var unavailable = new List<FileRemoteProtocol>();
        Exception? firstFailure = null;
        var sourceCount = 0;
        var truncated = false;
        foreach (var protocol in protocols)
        {
            cancellationToken.ThrowIfCancellationRequested();
            try
            {
                var result = await LoadRemoteProtocolAsync(protocol, cancellationToken)
                    .ConfigureAwait(false);
                staged.AddRange(result.Items);
                sourceCount = checked(sourceCount + result.SourceCount);
                truncated |= result.Truncated;
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (DsmException error) when (IsAuthenticationOrSessionFailure(error))
            {
                throw;
            }
            catch (DsmException error)
            {
                unavailable.Add(protocol);
                firstFailure ??= error;
            }
            catch (JsonException error)
            {
                unavailable.Add(protocol);
                firstFailure ??= error;
            }
            catch (IOException error)
            {
                unavailable.Add(protocol);
                firstFailure ??= error;
            }
        }
        if (unavailable.Count == protocols.Count)
        {
            throw firstFailure ?? InvalidLocationsResponse("remote.all_protocols_failed");
        }

        var unique = new Dictionary<string, FileRemoteLocation>(StringComparer.Ordinal);
        foreach (var item in staged)
        {
            unique.TryAdd($"{ProtocolValue(item.Protocol)}|{item.Path}", item);
        }
        var sorted = unique.Values
            .OrderBy(item => item.Name, StringComparer.OrdinalIgnoreCase)
            .ThenBy(item => item.Path, StringComparer.Ordinal)
            .ThenBy(item => item.Protocol)
            .ToArray();
        truncated |= sorted.Length > RemoteResultLimit;
        var bounded = sorted.Take(RemoteResultLimit).ToArray();
        return new FileRemoteSnapshot(
            bounded,
            bounded.Length,
            sourceCount,
            unavailable,
            unavailable.Count > 0,
            truncated ? FileLocationCompletion.Truncated : FileLocationCompletion.Complete,
            FileLocationSectionStatus.Available);
    }

    private async Task<RemoteProtocolResult> LoadRemoteProtocolAsync(
        FileRemoteProtocol protocol,
        CancellationToken cancellationToken)
    {
        var items = new List<FileRemoteLocation>();
        var offset = 0;
        int? expectedTotal = null;
        while (offset < RemoteProtocolLimit)
        {
            var requestLimit = Math.Min(RemotePageSize, RemoteProtocolLimit - offset);
            var parameters = PageParameters(offset, requestLimit);
            parameters["type"] = ProtocolValue(protocol);
            parameters["sort_by"] = "name";
            parameters["sort_direction"] = "asc";
            parameters["additional"] = "[\"mount_point_type\",\"perm\"]";
            var data = await CallLocationReadAsync(
                "SYNO.FileStation.VirtualFolder",
                "list",
                parameters,
                cancellationToken).ConfigureAwait(false);
            var page = RequiredArray(data, "folders");
            if (page.Count > requestLimit)
            {
                throw InvalidLocationsResponse("remote.page_limit");
            }
            var responseOffset = LocationRequiredNonNegativeInt(data, "offset");
            var total = LocationRequiredNonNegativeInt(data, "total");
            if (responseOffset != offset || responseOffset > total ||
                page.Count > total - responseOffset ||
                expectedTotal is { } stable && stable != total)
            {
                throw InvalidLocationsResponse("remote.pagination");
            }
            expectedTotal ??= total;
            if (page.Count == 0 && offset < Math.Min(total, RemoteProtocolLimit))
            {
                throw InvalidLocationsResponse("remote.zero_progress");
            }
            foreach (var node in page)
            {
                var item = RequiredObject(node, "remote.item");
                var name = LocationRequiredString(item, "name").Trim();
                ValidateLocationName(name);
                var path = CanonicalDirectoryPath(LocationRequiredString(item, "path"));
                if (!RequiredNativeBool(item, "isdir"))
                {
                    throw InvalidLocationsResponse("remote.not_directory");
                }
                var advertisedType = OptionalMountPointType(item);
                if (advertisedType is not null &&
                    !string.Equals(advertisedType, ProtocolValue(protocol), StringComparison.OrdinalIgnoreCase))
                {
                    throw InvalidLocationsResponse("remote.protocol_mismatch");
                }
                ValidateOptionalPermission(item);
                items.Add(new FileRemoteLocation(
                    ProfileId,
                    $"{ProtocolValue(protocol)}:{path}",
                    name,
                    path,
                    protocol,
                    protocol == FileRemoteProtocol.Iso));
            }
            var nextOffset = checked(offset + page.Count);
            var boundedTotal = Math.Min(total, RemoteProtocolLimit);
            if (nextOffset > boundedTotal)
            {
                throw InvalidLocationsResponse("remote.pagination_overrun");
            }
            if (nextOffset >= boundedTotal)
            {
                return new RemoteProtocolResult(items, total, total > RemoteProtocolLimit);
            }
            offset = nextOffset;
        }
        return new RemoteProtocolResult(items, expectedTotal ?? items.Count, true);
    }

    private static IReadOnlyList<FileRemoteProtocol> ParseSupportedProtocols(JsonObject info)
    {
        var values = new List<string>();
        switch (info["support_virtual_protocol"])
        {
            case JsonValue scalar when scalar.TryGetValue<string>(out var text):
                values.AddRange(text.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries));
                break;
            case JsonArray array:
                foreach (var node in array)
                {
                    if (node is not JsonValue value || !value.TryGetValue<string>(out var item))
                    {
                        throw InvalidLocationsResponse("remote.protocol_shape");
                    }
                    values.Add(item);
                }
                break;
            case null:
                return [];
            default:
                throw InvalidLocationsResponse("remote.protocol_shape");
        }
        return values
            .Select(value => value.Trim().ToLowerInvariant())
            .Select(value => value switch
            {
                "cifs" => FileRemoteProtocol.Cifs,
                "nfs" => FileRemoteProtocol.Nfs,
                "iso" => FileRemoteProtocol.Iso,
                _ => (FileRemoteProtocol?)null,
            })
            .Where(value => value.HasValue)
            .Select(value => value!.Value)
            .Distinct()
            .ToArray();
    }

    private static Dictionary<string, string> PageParameters(int offset, int limit) => new()
    {
        ["offset"] = offset.ToString(CultureInfo.InvariantCulture),
        ["limit"] = limit.ToString(CultureInfo.InvariantCulture),
    };

    private static JsonArray RequiredArray(JsonObject value, string name) =>
        value[name] as JsonArray ?? throw InvalidLocationsResponse("json.array");

    private static JsonObject RequiredObject(JsonNode? value, string diagnostic) =>
        value as JsonObject ?? throw InvalidLocationsResponse(diagnostic);

    private static int LocationRequiredNonNegativeInt(JsonObject value, string name)
    {
        if (value[name] is not JsonValue node || !node.TryGetValue<int>(out var result) || result < 0)
        {
            throw InvalidLocationsResponse("json.nonnegative_int");
        }
        return result;
    }

    private static string LocationRequiredString(JsonObject value, string name)
    {
        if (value[name] is not JsonValue node || !node.TryGetValue<string>(out var result))
        {
            throw InvalidLocationsResponse("json.string");
        }
        return result;
    }

    private static string? LocationOptionalString(JsonObject value, string name)
    {
        if (!value.ContainsKey(name) || value[name] is null)
        {
            return null;
        }
        if (value[name] is not JsonValue node || !node.TryGetValue<string>(out var result))
        {
            throw InvalidLocationsResponse("json.optional_string");
        }
        return result;
    }

    private static bool RequiredNativeBool(JsonObject value, string name)
    {
        if (value[name] is not JsonValue node || !node.TryGetValue<bool>(out var result))
        {
            throw InvalidLocationsResponse("json.bool");
        }
        return result;
    }

    private static string? OptionalMountPointType(JsonObject item)
    {
        if (!item.ContainsKey("additional") || item["additional"] is null)
        {
            return null;
        }
        var additional = item["additional"] as JsonObject
            ?? throw InvalidLocationsResponse("json.additional_object");
        return LocationOptionalString(additional, "mount_point_type")?.Trim().ToLowerInvariant();
    }

    private static void ValidateOptionalPermission(JsonObject item)
    {
        if (item["additional"] is not JsonObject additional ||
            !additional.ContainsKey("perm") || additional["perm"] is null)
        {
            return;
        }
        var permission = additional["perm"] as JsonObject
            ?? throw InvalidLocationsResponse("remote.permission_object");
        if (permission.ContainsKey("posix") && permission["posix"] is not null &&
            (permission["posix"] is not JsonValue posix || !posix.TryGetValue<int>(out _)))
        {
            throw InvalidLocationsResponse("remote.permission_posix");
        }
        if (!permission.ContainsKey("adv_right") || permission["adv_right"] is null)
        {
            return;
        }
        var rights = permission["adv_right"] as JsonObject
            ?? throw InvalidLocationsResponse("remote.permission_rights");
        if (rights.Any(pair => pair.Value is not JsonValue value || !value.TryGetValue<bool>(out _)))
        {
            throw InvalidLocationsResponse("remote.permission_right");
        }
    }

    private static string CanonicalDirectoryPath(string value)
    {
        if (string.IsNullOrWhiteSpace(value) || value.Length > 4_096 || value[0] != '/' ||
            value == "/" || value.EndsWith("/", StringComparison.Ordinal) ||
            value.Contains("//", StringComparison.Ordinal) || value.Contains('\\') ||
            value.Any(char.IsControl))
        {
            throw InvalidLocationsResponse("path.canonical");
        }
        var segments = value.Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (segments.Length == 0 || segments.Any(segment => segment is "." or ".."))
        {
            throw InvalidLocationsResponse("path.canonical");
        }
        return value;
    }

    private static void ValidateLocationName(string value)
    {
        if (string.IsNullOrWhiteSpace(value) || value.Length > 1_024 || value.Any(char.IsControl))
        {
            throw InvalidLocationsResponse("name.invalid");
        }
    }

    private static bool IsLocalShareMountType(string? value) =>
        string.IsNullOrEmpty(value) || value is "normal" or "shared_folder";

    private static bool IsAuthenticationOrSessionFailure(DsmException error) =>
        error.Code is 106 or 107 or 119 or 401;

    private static string RecyclePath(string sharePath) => $"{sharePath}/#recycle";

    private static string ProtocolValue(FileRemoteProtocol value) => value switch
    {
        FileRemoteProtocol.Cifs => "cifs",
        FileRemoteProtocol.Nfs => "nfs",
        FileRemoteProtocol.Iso => "iso",
        _ => throw new ArgumentOutOfRangeException(nameof(value)),
    };

    private static InvalidDataException InvalidLocationsResponse(string diagnostic) =>
        new($"file.locations.invalid_response.{diagnostic}");

    private static FileFavoriteSnapshot UnavailableFavorites() =>
        new([], 0, 0, FileLocationCompletion.Complete, FileLocationSectionStatus.Unavailable);

    private static FileFavoriteSnapshot FailedFavorites(string diagnosticTag) =>
        new([], 0, 0, FileLocationCompletion.Complete, FileLocationSectionStatus.Failed, diagnosticTag);

    private static FileRecycleSnapshot UnavailableRecycleBins() =>
        new([], 0, 0, 0, false, FileLocationCompletion.Complete, FileLocationSectionStatus.Unavailable);

    private static FileRecycleSnapshot FailedRecycleBins(string diagnosticTag) =>
        new([], 0, 0, 0, false, FileLocationCompletion.Complete, FileLocationSectionStatus.Failed, diagnosticTag);

    private static FileRemoteSnapshot UnavailableRemoteLocations() =>
        new([], 0, 0, [], false, FileLocationCompletion.Complete, FileLocationSectionStatus.Unavailable);

    private static FileRemoteSnapshot AvailableEmptyRemoteLocations() =>
        new([], 0, 0, [], false, FileLocationCompletion.Complete, FileLocationSectionStatus.Available);

    private static FileRemoteSnapshot FailedRemoteLocations(string diagnosticTag) =>
        new([], 0, 0, [], false, FileLocationCompletion.Complete, FileLocationSectionStatus.Failed, diagnosticTag);

    private sealed record ShareCandidate(string Name, string Path);
    private sealed record RecycleProbeResult(ShareCandidate Share, RecycleProbeStatus Status);
    private enum RecycleProbeStatus { Accessible, NotFound, PermissionDenied }
    private sealed record RemoteProtocolResult(
        IReadOnlyList<FileRemoteLocation> Items,
        int SourceCount,
        bool Truncated);
}
