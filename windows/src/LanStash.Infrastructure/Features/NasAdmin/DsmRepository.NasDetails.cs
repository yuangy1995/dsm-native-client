using System.Globalization;
using System.IO;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private const int NasDetailsPageLimit = 50;
    private const int ShareAccessApiVersion = 2;
    private const int ShareAccessPageSize = 200;
    private const int ShareAccessSourceLimit = 500;

    NasDetailsAvailability INasDetailsRepository.Availability => NasDetailsAvailability;

    private NasDetailsAvailability NasDetailsAvailability
    {
        get
        {
            var features = new HashSet<NasDetailsReadFeature>();
            if (Supports("SYNO.Core.System"))
            {
                features.Add(NasDetailsReadFeature.SystemOverview);
            }
            if (Supports("SYNO.Storage.CGI.Storage"))
            {
                features.Add(NasDetailsReadFeature.StorageHealth);
            }
            if (Supports("SYNO.Core.Upgrade.Server"))
            {
                features.Add(NasDetailsReadFeature.SystemUpdate);
            }
            if (SupportsShareAccess())
            {
                features.Add(NasDetailsReadFeature.ShareAccess);
            }
            if (Supports("SYNO.Core.Package"))
            {
                features.Add(NasDetailsReadFeature.Packages);
            }
            if (Supports("SYNO.Core.TaskScheduler"))
            {
                features.Add(NasDetailsReadFeature.ScheduledTasks);
            }
            if (Supports("SYNO.LogCenter.History") || Supports("SYNO.Core.SyslogClient.Log"))
            {
                features.Add(NasDetailsReadFeature.Logs);
            }
            if (Supports("SYNO.Core.CurrentConnection"))
            {
                features.Add(NasDetailsReadFeature.Connections);
            }
            return new NasDetailsAvailability(
                features.Count == 0
                    ? NasDetailsAvailabilityStatus.Unavailable
                    : NasDetailsAvailabilityStatus.Available,
                features);
        }
    }

    public async Task<NasDetailsSnapshot> LoadDetailsAsync(
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var systemOverview = await LoadSystemOverviewSectionAsync(cancellationToken)
            .ConfigureAwait(false);
        return new NasDetailsSnapshot(
            _profile.Id,
            systemOverview,
            await LoadStorageHealthSectionAsync(cancellationToken).ConfigureAwait(false),
            await LoadSystemUpdateSectionAsync(systemOverview, cancellationToken).ConfigureAwait(false),
            await LoadShareAccessSectionAsync(cancellationToken).ConfigureAwait(false),
            await LoadPackagesSectionAsync(cancellationToken).ConfigureAwait(false),
            await LoadScheduledTasksSectionAsync(cancellationToken).ConfigureAwait(false),
            await LoadLogsSectionAsync(cancellationToken).ConfigureAwait(false),
            await LoadConnectionsSectionAsync(cancellationToken).ConfigureAwait(false));
    }

    private bool SupportsShareAccess() =>
        _capabilities.TryGetValue("SYNO.FileStation.List", out var capability) &&
        string.Equals(capability.Name, "SYNO.FileStation.List", StringComparison.Ordinal) &&
        capability.MinVersion <= ShareAccessApiVersion &&
        capability.MaxVersion >= ShareAccessApiVersion &&
        string.Equals(capability.RequestFormat, "FORM", StringComparison.OrdinalIgnoreCase);

    private async Task<NasDetailsSection<NasShareAccessSummary>> LoadShareAccessSectionAsync(
        CancellationToken cancellationToken)
    {
        if (!SupportsShareAccess())
        {
            return Unavailable<NasShareAccessSummary>("nas-details.share-access.unavailable");
        }
        try
        {
            var candidates = new Dictionary<string, ShareAccessCandidate>(StringComparer.Ordinal);
            var offset = 0;
            int? expectedTotal = null;
            var sourceTruncated = false;
            while (offset < ShareAccessSourceLimit)
            {
                var requestLimit = Math.Min(ShareAccessPageSize, ShareAccessSourceLimit - offset);
                var data = await _api.CallReadJsonObjectAsync(
                    _profile,
                    _session,
                    Required("SYNO.FileStation.List"),
                    ShareAccessApiVersion,
                    "list_share",
                    new Dictionary<string, string>(StringComparer.Ordinal)
                    {
                        ["offset"] = offset.ToString(CultureInfo.InvariantCulture),
                        ["limit"] = requestLimit.ToString(CultureInfo.InvariantCulture),
                        ["sort_by"] = "name",
                        ["sort_direction"] = "asc",
                        ["additional"] = "[\"mount_point_type\",\"perm\"]",
                    },
                    cancellationToken).ConfigureAwait(false);
                var page = ShareAccessRequiredArray(data, "shares");
                var responseOffset = ShareAccessRequiredNonnegativeInt(data, "offset");
                var total = ShareAccessRequiredNonnegativeInt(data, "total");
                if (page.Count > requestLimit || responseOffset != offset || responseOffset > total ||
                    page.Count > total - responseOffset ||
                    expectedTotal is { } stableTotal && stableTotal != total)
                {
                    throw new InvalidDataException("Invalid shared-folder pagination.");
                }
                expectedTotal ??= total;
                if (page.Count == 0 && offset < Math.Min(total, ShareAccessSourceLimit))
                {
                    throw new InvalidDataException("Shared-folder pagination made no progress.");
                }
                foreach (var node in page)
                {
                    var item = node as JsonObject
                        ?? throw new InvalidDataException("Invalid shared-folder item.");
                    var path = ShareAccessRequiredPath(item, "path");
                    var name = ShareAccessRequiredName(item, "name");
                    if (!ShareAccessRequiredBoolean(item, "isdir") || IsRecycleShare(path, name))
                    {
                        continue;
                    }
                    var additional = ShareAccessOptionalObject(item, "additional");
                    var mountType = ShareAccessOptionalText(additional, "mount_point_type")
                        ?.ToLowerInvariant();
                    if (mountType is not null and not ("normal" or "shared_folder"))
                    {
                        continue;
                    }
                    var rights = ShareAccessOptionalObject(
                        ShareAccessOptionalObject(additional, "perm"),
                        "adv_right");
                    var canRead = ShareAccessOptionalBoolean(rights, "read");
                    var canWrite = ShareAccessOptionalBoolean(rights, "write");
                    var canDelete = ShareAccessOptionalBoolean(rights, "delete");
                    var accessLevel = canWrite == true
                        ? NasShareAccessLevel.ReadWrite
                        : canRead == true
                            ? NasShareAccessLevel.ReadOnly
                            : NasShareAccessLevel.Unknown;
                    candidates[path] = new ShareAccessCandidate(name, accessLevel, canDelete == true);
                }
                var nextOffset = checked(offset + page.Count);
                var boundedTotal = Math.Min(total, ShareAccessSourceLimit);
                if (nextOffset > boundedTotal)
                {
                    throw new InvalidDataException("Shared-folder pagination exceeded its bound.");
                }
                if (nextOffset >= boundedTotal)
                {
                    sourceTruncated = total > ShareAccessSourceLimit;
                    break;
                }
                offset = nextOffset;
            }
            var ordered = candidates.Values
                .OrderBy(item => item.Name, StringComparer.CurrentCultureIgnoreCase)
                .ThenBy(item => item.Name, StringComparer.Ordinal)
                .Select((item, index) => new NasShareAccessSummary(
                    $"share-{index + 1}",
                    item.Name,
                    item.AccessLevel,
                    item.CanDelete))
                .ToArray();
            var section = Available<NasShareAccessSummary>(ordered);
            return section with { IsTruncated = section.IsTruncated || sourceTruncated };
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception error) when (IsNasDetailsReadFailure(error))
        {
            return Failed<NasShareAccessSummary>("nas-details.share-access.failed");
        }
    }

    private static JsonArray ShareAccessRequiredArray(JsonObject value, string key) =>
        value[key] as JsonArray ?? throw new InvalidDataException("Invalid shared-folder list.");

    private static int ShareAccessRequiredNonnegativeInt(JsonObject value, string key) =>
        value[key] is JsonValue node && node.TryGetValue<int>(out var result) && result >= 0
            ? result
            : throw new InvalidDataException("Invalid shared-folder count.");

    private static string ShareAccessRequiredPath(JsonObject value, string key)
    {
        var result = value[key] is JsonValue node && node.TryGetValue<string>(out var text)
            ? text.Trim()
            : null;
        if (string.IsNullOrWhiteSpace(result) || result.Length > 4_096 || result[0] != '/' ||
            result.EndsWith("/", StringComparison.Ordinal) ||
            result.Contains("//", StringComparison.Ordinal) || result.Contains('\\') ||
            result.Any(char.IsControl) ||
            result.Split('/', StringSplitOptions.RemoveEmptyEntries)
                .Any(segment => segment is "." or ".."))
        {
            throw new InvalidDataException("Invalid shared-folder path.");
        }
        return result;
    }

    private static string ShareAccessRequiredName(JsonObject value, string key)
    {
        var result = value[key] is JsonValue node && node.TryGetValue<string>(out var text)
            ? text.Trim()
            : null;
        return !string.IsNullOrWhiteSpace(result) && result.Length <= 1_024 &&
            !result.Any(char.IsControl) && !result.Contains('/') && !result.Contains('\\')
                ? result
                : throw new InvalidDataException("Invalid shared-folder name.");
    }

    private static JsonObject? ShareAccessOptionalObject(JsonObject? value, string key)
    {
        if (value is null || !value.ContainsKey(key) || value[key] is null)
        {
            return null;
        }
        return value[key] as JsonObject
            ?? throw new InvalidDataException("Invalid shared-folder object.");
    }

    private static string? ShareAccessOptionalText(JsonObject? value, string key)
    {
        if (value is null || !value.ContainsKey(key) || value[key] is null)
        {
            return null;
        }
        if (value[key] is not JsonValue node || !node.TryGetValue<string>(out var text))
        {
            throw new InvalidDataException("Invalid shared-folder text.");
        }
        return string.IsNullOrWhiteSpace(text) ? null : text.Trim();
    }

    private static bool ShareAccessRequiredBoolean(JsonObject value, string key) =>
        value[key] is JsonValue node && node.TryGetValue<bool>(out var result)
            ? result
            : throw new InvalidDataException("Invalid shared-folder type.");

    private static bool? ShareAccessOptionalBoolean(JsonObject? value, string key)
    {
        if (value is null || !value.ContainsKey(key) || value[key] is null)
        {
            return null;
        }
        return value[key] is JsonValue node && node.TryGetValue<bool>(out var result)
            ? result
            : throw new InvalidDataException("Invalid shared-folder permission.");
    }

    private static bool IsRecycleShare(string path, string name) =>
        string.Equals(name, "#recycle", StringComparison.OrdinalIgnoreCase) ||
        string.Equals(path.Split('/').LastOrDefault(), "#recycle", StringComparison.OrdinalIgnoreCase);

    private sealed record ShareAccessCandidate(
        string Name,
        NasShareAccessLevel AccessLevel,
        bool CanDelete);

    private async Task<NasDetailsSection<NasSystemUpdateSummary>> LoadSystemUpdateSectionAsync(
        NasDetailsSection<NasSystemHealthSummary> systemOverview,
        CancellationToken cancellationToken)
    {
        if (!Supports("SYNO.Core.Upgrade.Server"))
        {
            return Unavailable<NasSystemUpdateSummary>("nas-details.update.unavailable");
        }
        try
        {
            var data = await _api.CallReadJsonObjectAsync(
                _profile,
                _session,
                Required("SYNO.Core.Upgrade.Server"),
                3,
                "check",
                new Dictionary<string, string>(StringComparer.Ordinal)
                {
                    ["user_reading"] = "true",
                    ["need_auto_smallupdate"] = "true",
                    ["need_promotion"] = "false",
                },
                cancellationToken).ConfigureAwait(false);
            var update = data.Object("update");
            var currentVersion = systemOverview.Items.FirstOrDefault()?.Version;
            var latestVersion = update is null
                ? null
                : RequiredDisplayString(update, "version");
            var releaseNotes = update is null
                ? null
                : RequiredDisplayString(update, "release_note")
                    ?? RequiredDisplayString(update, "release_notes")
                    ?? RequiredDisplayString(update, "whats_new")
                    ?? RequiredDisplayString(update, "description");
            return Available<NasSystemUpdateSummary>(
            [
                new(
                    latestVersion is not null && latestVersion != currentVersion,
                    currentVersion,
                    latestVersion,
                    releaseNotes),
            ]);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception error) when (IsNasDetailsReadFailure(error))
        {
            return Failed<NasSystemUpdateSummary>("nas-details.update.failed");
        }
    }

    private async Task<NasDetailsSection<NasSystemHealthSummary>> LoadSystemOverviewSectionAsync(
        CancellationToken cancellationToken)
    {
        if (!Supports("SYNO.Core.System"))
        {
            return Unavailable<NasSystemHealthSummary>("nas-details.system.unavailable");
        }
        try
        {
            var data = await _api.CallReadJsonObjectAsync(
                _profile,
                _session,
                Required("SYNO.Core.System"),
                3,
                "info",
                cancellationToken: cancellationToken).ConfigureAwait(false);
            var rawMemory = data.Long("ram_size") ?? data.Long("memory_size");
            var item = new NasSystemHealthSummary(
                RequiredDisplayString(data, "model"),
                RequiredDisplayString(data, "firmware_ver")
                    ?? RequiredDisplayString(data, "version"),
                ParseUptimeSeconds(data.String("up_time") ?? data.String("uptime")),
                RequiredDisplayString(data, "cpu_series")
                    ?? RequiredDisplayString(data, "cpu_family")
                    ?? RequiredDisplayString(data, "cpu_model"),
                data.Int("cpu_cores"),
                data.Int("cpu_clock_speed"),
                NormalizeMemoryBytes(rawMemory),
                JsonNumber(data, "sys_temp"),
                data.Bool("temperature_warning")
                    ?? data.Bool("sys_tempwarn")
                    ?? data.Bool("systempwarn")
                    ?? false);
            return Available<NasSystemHealthSummary>([item]);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception error) when (IsNasDetailsReadFailure(error))
        {
            return Failed<NasSystemHealthSummary>("nas-details.system.failed");
        }
    }

    private async Task<NasDetailsSection<NasStorageHealthSummary>> LoadStorageHealthSectionAsync(
        CancellationToken cancellationToken)
    {
        if (!Supports("SYNO.Storage.CGI.Storage"))
        {
            return Unavailable<NasStorageHealthSummary>("nas-details.storage.unavailable");
        }
        try
        {
            var data = await _api.CallReadJsonObjectAsync(
                _profile,
                _session,
                Required("SYNO.Storage.CGI.Storage"),
                1,
                "load_info",
                cancellationToken: cancellationToken).ConfigureAwait(false);
            var items = ParseStorageItems(data)
                .Take(NasDetailsPageLimit + 1)
                .ToArray();
            return Available(items);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception error) when (IsNasDetailsReadFailure(error))
        {
            return Failed<NasStorageHealthSummary>("nas-details.storage.failed");
        }
    }

    private static IEnumerable<NasStorageHealthSummary> ParseStorageItems(JsonObject data)
    {
        var pools = data.Array("storagePools").OfType<JsonObject>();
        var volumes = data.Array("volumes").OfType<JsonObject>();
        var drives = data.Array("disks").OfType<JsonObject>();
        return pools.Select((item, index) =>
            StorageItem(item, NasStorageItemKind.Pool, index + 1))
            .Concat(volumes.Select((item, index) =>
                StorageItem(item, NasStorageItemKind.Volume, index + 1)))
            .Concat(drives.Select((item, index) =>
                StorageItem(item, NasStorageItemKind.Drive, index + 1)));
    }

    private static NasStorageHealthSummary StorageItem(
        JsonObject item,
        NasStorageItemKind kind,
        int ordinal)
    {
        var size = item.Object("size");
        var status = RequiredDisplayString(item, "summary_status")
            ?? RequiredDisplayString(item, "summary_status_key")
            ?? RequiredDisplayString(item, "drive_status_key")
            ?? RequiredDisplayString(item, "space_status")
            ?? RequiredDisplayString(item, "overview_status")
            ?? RequiredDisplayString(item, "status");
        return new NasStorageHealthSummary(
            $"{kind.ToString().ToLowerInvariant()}-{ordinal}",
            kind,
            ordinal,
            status,
            ParseState(status),
            Nonnegative(size?.Long("total") ?? item.Long("size_total")),
            Nonnegative(size?.Long("used")),
            kind == NasStorageItemKind.Volume
                ? RequiredDisplayString(item, "fs_type")
                : null,
            kind == NasStorageItemKind.Pool
                ? RequiredDisplayString(item, "raidType")
                    ?? RequiredDisplayString(item, "device_type")
                : null,
            kind == NasStorageItemKind.Drive
                ? RequiredDisplayString(item, "smart_status")
                : null,
            kind == NasStorageItemKind.Drive ? JsonNumber(item, "temp") : null,
            kind == NasStorageItemKind.Drive && (item.Bool("isSsd") ?? false),
            kind == NasStorageItemKind.Volume && (item.Bool("is_encrypted") ?? false));
    }

    private async Task<NasDetailsSection<NasPackageSummary>> LoadPackagesSectionAsync(
        CancellationToken cancellationToken)
    {
        if (!Supports("SYNO.Core.Package"))
        {
            return Unavailable<NasPackageSummary>("nas-details.packages.unavailable");
        }
        try
        {
            var data = await _api.CallReadJsonObjectAsync(
                _profile,
                _session,
                Required("SYNO.Core.Package"),
                2,
                "list",
                new Dictionary<string, string>(StringComparer.Ordinal)
                {
                    ["additional"] = "[\"status\"]",
                },
                cancellationToken).ConfigureAwait(false);
            var items = SectionArray(data, "packages", "items", "data")
                .OfType<JsonObject>()
                .Take(NasDetailsPageLimit + 1)
                .Select((item, index) =>
                {
                    var id = RequiredDisplayString(item, "id")
                        ?? RequiredDisplayString(item, "name")
                        ?? $"package-{index}";
                    var name = RequiredDisplayString(item, "name")
                        ?? RequiredDisplayString(item, "title")
                        ?? id;
                    var status = RequiredDisplayString(item, "status")
                        ?? RequiredDisplayString(item, "state")
                        ?? "unknown";
                    return new NasPackageSummary(
                        id,
                        name,
                        RequiredDisplayString(item, "version")
                            ?? RequiredDisplayString(item, "ver"),
                        status,
                        ParseState(status));
                })
                .DistinctBy(item => item.Id)
                .ToArray();
            return Available(items);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception error) when (IsNasDetailsReadFailure(error))
        {
            return Failed<NasPackageSummary>("nas-details.packages.failed");
        }
    }

    private async Task<NasDetailsSection<NasScheduledTaskSummary>> LoadScheduledTasksSectionAsync(
        CancellationToken cancellationToken)
    {
        if (!Supports("SYNO.Core.TaskScheduler"))
        {
            return Unavailable<NasScheduledTaskSummary>("nas-details.tasks.unavailable");
        }
        try
        {
            var data = await _api.CallReadJsonObjectAsync(
                _profile,
                _session,
                Required("SYNO.Core.TaskScheduler"),
                3,
                "list",
                FirstPageParameters(),
                cancellationToken).ConfigureAwait(false);
            var items = SectionArray(data, "tasks", "task", "items", "data", "list")
                .OfType<JsonObject>()
                .Take(NasDetailsPageLimit + 1)
                .Select((item, index) =>
                {
                    var id = RequiredDisplayString(item, "id")
                        ?? RequiredDisplayString(item, "task_id")
                        ?? RequiredDisplayString(item, "name")
                        ?? $"task-{index}";
                    var name = RequiredDisplayString(item, "name")
                        ?? RequiredDisplayString(item, "task_name")
                        ?? id;
                    return new NasScheduledTaskSummary(
                        id,
                        name,
                        item.Bool("enable") ?? item.Bool("enabled"),
                        RequiredDisplayString(item, "next_trigger_time")
                            ?? RequiredDisplayString(item, "next_run")
                            ?? RequiredDisplayString(item, "schedule"));
                })
                .DistinctBy(item => item.Id)
                .ToArray();
            return Available(items);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception error) when (IsNasDetailsReadFailure(error))
        {
            return Failed<NasScheduledTaskSummary>("nas-details.tasks.failed");
        }
    }

    private async Task<NasDetailsSection<NasLogSummary>> LoadLogsSectionAsync(
        CancellationToken cancellationToken)
    {
        var apiName = PreferredOptional("SYNO.LogCenter.History", "SYNO.Core.SyslogClient.Log");
        if (apiName is null)
        {
            return Unavailable<NasLogSummary>("nas-details.logs.unavailable");
        }
        try
        {
            var data = await _api.CallReadJsonObjectAsync(
                _profile,
                _session,
                Required(apiName),
                1,
                "list",
                FirstPageParameters(),
                cancellationToken).ConfigureAwait(false);
            var items = SectionArray(data, "logs", "log", "records", "events", "items", "data", "list")
                .OfType<JsonObject>()
                .Take(NasDetailsPageLimit + 1)
                .Select((item, index) =>
                {
                    var source = RequiredDisplayString(item, "source")
                        ?? RequiredDisplayString(item, "service")
                        ?? RequiredDisplayString(item, "type")
                        ?? "System";
                    return new NasLogSummary(
                        RequiredDisplayString(item, "id")
                            ?? RequiredDisplayString(item, "log_id")
                            ?? $"log-{index}",
                        item.Date("time")
                            ?? item.Date("timestamp")
                            ?? item.Date("date")
                            ?? item.Date("event_time")
                            ?? item.Date("create_time"),
                        source,
                        RequiredDisplayString(item, "level")
                            ?? RequiredDisplayString(item, "severity")
                            ?? "unknown");
                })
                .DistinctBy(item => item.Id)
                .ToArray();
            return Available(items);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception error) when (IsNasDetailsReadFailure(error))
        {
            return Failed<NasLogSummary>("nas-details.logs.failed");
        }
    }

    private async Task<NasDetailsSection<NasConnectionSummary>> LoadConnectionsSectionAsync(
        CancellationToken cancellationToken)
    {
        if (!Supports("SYNO.Core.CurrentConnection"))
        {
            return Unavailable<NasConnectionSummary>("nas-details.connections.unavailable");
        }
        try
        {
            var data = await _api.CallReadJsonObjectAsync(
                _profile,
                _session,
                Required("SYNO.Core.CurrentConnection"),
                1,
                "list",
                FirstPageParameters(),
                cancellationToken).ConfigureAwait(false);
            var items = SectionArray(data, "connections", "items", "data", "list")
                .OfType<JsonObject>()
                .Take(NasDetailsPageLimit + 1)
                .Select((item, index) => new NasConnectionSummary(
                    RequiredDisplayString(item, "id")
                        ?? RequiredDisplayString(item, "conn_id")
                        ?? $"connection-{index}",
                    RequiredDisplayString(item, "protocol")
                        ?? RequiredDisplayString(item, "service")
                        ?? "unknown",
                    RequiredDisplayString(item, "type")
                        ?? RequiredDisplayString(item, "connection_type")
                        ?? "active",
                    item.Date("time")
                        ?? item.Date("login_time")
                        ?? item.Date("connected_at")
                        ?? item.Date("start_time"),
                    item.Bool("is_current") ?? item.Bool("current") ?? false))
                .DistinctBy(item => item.Id)
                .ToArray();
            return Available(items);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception error) when (IsNasDetailsReadFailure(error))
        {
            return Failed<NasConnectionSummary>("nas-details.connections.failed");
        }
    }

    private static Dictionary<string, string> FirstPageParameters() =>
        new(StringComparer.Ordinal)
        {
            ["start"] = "0",
            ["limit"] = NasDetailsPageLimit.ToString(CultureInfo.InvariantCulture),
        };

    private static NasDetailsSection<T> Available<T>(IReadOnlyList<T> rawItems)
    {
        var truncated = rawItems.Count > NasDetailsPageLimit;
        return new NasDetailsSection<T>(
            NasDetailsSectionStatus.Available,
            truncated ? rawItems.Take(NasDetailsPageLimit).ToArray() : rawItems,
            truncated);
    }

    private static NasDetailsSection<T> Unavailable<T>(string tag) =>
        new(NasDetailsSectionStatus.Unavailable, [], DiagnosticTag: tag);

    private static NasDetailsSection<T> Failed<T>(string tag) =>
        new(NasDetailsSectionStatus.Failed, [], DiagnosticTag: tag);

    private static bool IsNasDetailsReadFailure(Exception error) =>
        error is DsmException or JsonException or InvalidDataException or NotSupportedException;

    private static IEnumerable<JsonNode?> SectionArray(JsonObject data, params string[] roots) =>
        roots.SelectMany(data.Array);

    private static string? RequiredDisplayString(JsonObject item, string key)
    {
        var value = item.String(key);
        return string.IsNullOrWhiteSpace(value) ? null : value.Trim();
    }

    private static long? ParseUptimeSeconds(string? value)
    {
        if (long.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out var seconds))
        {
            return Nonnegative(seconds);
        }
        var parts = value?.Split(':');
        if (parts is not { Length: 3 } ||
            !long.TryParse(parts[0], NumberStyles.Integer, CultureInfo.InvariantCulture, out var hours) ||
            !long.TryParse(parts[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out var minutes) ||
            !long.TryParse(parts[2], NumberStyles.Integer, CultureInfo.InvariantCulture, out var remainingSeconds) ||
            hours < 0 || minutes is < 0 or > 59 || remainingSeconds is < 0 or > 59)
        {
            return null;
        }
        return hours <= (long.MaxValue - (minutes * 60) - remainingSeconds) / 3600
            ? (hours * 3600) + (minutes * 60) + remainingSeconds
            : null;
    }

    private static long? NormalizeMemoryBytes(long? value)
    {
        if (value is null || value < 0)
        {
            return null;
        }
        return value < 1_000_000 && value <= long.MaxValue / (1024 * 1024)
            ? value * 1024 * 1024
            : value;
    }

    private static long? Nonnegative(long? value) => value >= 0 ? value : null;

    private static double? JsonNumber(JsonObject item, string key)
    {
        if (item[key] is not JsonValue node)
        {
            return null;
        }
        if (node.TryGetValue<double>(out var value) && double.IsFinite(value))
        {
            return value;
        }
        return double.TryParse(
            node.ToString().Trim('"'),
            NumberStyles.Float,
            CultureInfo.InvariantCulture,
            out value) && double.IsFinite(value)
                ? value
                : null;
    }
}
