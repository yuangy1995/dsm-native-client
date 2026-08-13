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
    private const int StorageAnalysisApiVersion = 2;
    private const int StorageAnalysisShareLimit = 20;
    private const int StorageAnalysisFilesPerShare = 50;
    private const int StorageAnalysisFileLimit = 500;
    private const int DeepStorageAnalysisShareLimit = 20;
    private const int DeepStorageAnalysisFolderLimit = 120;
    private const int DeepStorageAnalysisFoldersPerParent = 25;
    private const int DeepStorageAnalysisFilesPerFolder = 100;
    private const int DeepStorageAnalysisFileLimit = 3_000;
    private const int DeepStorageAnalysisDirectorySizeLimit = 4;
    private const int DeepStorageAnalysisDuplicateGroupLimit = 4;
    private const int DeepStorageAnalysisMd5FilesPerGroup = 3;
    private const int SystemActivityApiVersion = 1;
    private const int SystemActivitySourceLimit = 500;
    private const int SystemActivityMaximumTotal = 1_000_000;

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
            if (SupportsStorageAnalysis())
            {
                features.Add(NasDetailsReadFeature.StorageAnalysis);
            }
            if (SupportsSystemActivity("SYNO.Core.System.Process"))
            {
                features.Add(NasDetailsReadFeature.SystemActivity);
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
            await LoadSystemActivitySectionAsync(cancellationToken).ConfigureAwait(false),
            await LoadPackagesSectionAsync(cancellationToken).ConfigureAwait(false),
            await LoadScheduledTasksSectionAsync(cancellationToken).ConfigureAwait(false),
            await LoadLogsSectionAsync(cancellationToken).ConfigureAwait(false),
            await LoadConnectionsSectionAsync(cancellationToken).ConfigureAwait(false))
        {
            StorageAnalysis = await LoadStorageAnalysisAsync(cancellationToken)
                .ConfigureAwait(false),
        };
    }

    public Task<NasDetailsSection<NasStorageAnalysisSummary>> LoadStorageAnalysisAsync(
        CancellationToken cancellationToken = default) =>
        LoadStorageAnalysisSectionAsync(cancellationToken);

    public Task<NasDetailsSection<NasStorageAnalysisSummary>> LoadDeepStorageAnalysisAsync(
        CancellationToken cancellationToken = default) =>
        LoadDeepStorageAnalysisSectionAsync(cancellationToken);

    private bool SupportsSystemActivity(string apiName) =>
        _capabilities.TryGetValue(apiName, out var capability) &&
        string.Equals(capability.Name, apiName, StringComparison.Ordinal) &&
        capability.MinVersion <= SystemActivityApiVersion &&
        capability.MaxVersion >= SystemActivityApiVersion &&
        string.Equals(capability.RequestFormat, "FORM", StringComparison.OrdinalIgnoreCase);

    private async Task<NasDetailsSection<NasSystemActivitySummary>> LoadSystemActivitySectionAsync(
        CancellationToken cancellationToken)
    {
        const string processApi = "SYNO.Core.System.Process";
        const string groupApi = "SYNO.Core.System.ProcessGroup";
        if (!SupportsSystemActivity(processApi))
        {
            return Unavailable<NasSystemActivitySummary>("nas-details.system-activity.unavailable");
        }
        try
        {
            var parameters = SystemActivityParameters();
            var data = await _api.CallReadJsonObjectAsync(
                _profile,
                _session,
                Required(processApi),
                SystemActivityApiVersion,
                "list",
                parameters,
                cancellationToken).ConfigureAwait(false);
            var processRows = SystemActivityRequiredArray(data, "processes", "items");
            if (processRows.Count > SystemActivitySourceLimit)
            {
                throw new InvalidDataException("System process list exceeded its bound.");
            }
            var processes = ParseSystemProcesses(processRows);
            var reportedTotal = SystemActivityOptionalTotal(data);
            if (reportedTotal is { } total && total < processRows.Count)
            {
                throw new InvalidDataException("System process total is smaller than the returned list.");
            }
            var visibleProcesses = processes.Take(NasDetailsPageLimit).ToArray();
            var isTruncated = processes.Count > visibleProcesses.Length ||
                (reportedTotal is { } reported
                    ? reported > processRows.Count
                    : processRows.Count == SystemActivitySourceLimit);

            IReadOnlyList<NasProcessGroupSummary> groups = [];
            var groupsUnavailable = !SupportsSystemActivity(groupApi);
            if (!groupsUnavailable)
            {
                try
                {
                    var groupData = await _api.CallReadJsonObjectAsync(
                        _profile,
                        _session,
                        Required(groupApi),
                        SystemActivityApiVersion,
                        "list",
                        SystemActivityParameters(),
                        cancellationToken).ConfigureAwait(false);
                    var groupRows = SystemActivityRequiredArray(groupData, "groups", "items");
                    if (groupRows.Count > SystemActivitySourceLimit)
                    {
                        throw new InvalidDataException("System process group list exceeded its bound.");
                    }
                    groups = ParseProcessGroups(groupRows);
                    var groupTotal = SystemActivityOptionalTotal(groupData);
                    if (groupTotal is { } reportedGroupTotal &&
                        reportedGroupTotal < groupRows.Count)
                    {
                        throw new InvalidDataException(
                            "System process group total is smaller than the returned list.");
                    }
                    groupsUnavailable = groupTotal is { } completeGroupTotal
                        ? completeGroupTotal > groupRows.Count
                        : groupRows.Count == SystemActivitySourceLimit;
                }
                catch (OperationCanceledException)
                {
                    throw;
                }
                catch (Exception error) when (IsNasDetailsReadFailure(error))
                {
                    groupsUnavailable = true;
                }
            }

            var visibleGroupIds = visibleProcesses
                .Select(item => item.GroupId)
                .OfType<string>()
                .ToHashSet(StringComparer.Ordinal);
            var visibleGroups = groups.Where(item => visibleGroupIds.Contains(item.Id)).ToArray();
            var section = Available<NasSystemActivitySummary>(
            [
                new(visibleProcesses, visibleGroups, groupsUnavailable),
            ]);
            return section with { IsTruncated = isTruncated };
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception error) when (IsNasDetailsReadFailure(error))
        {
            return Failed<NasSystemActivitySummary>("nas-details.system-activity.failed");
        }
    }

    private static Dictionary<string, string> SystemActivityParameters() =>
        new(StringComparer.Ordinal)
        {
            ["start"] = "0",
            ["limit"] = SystemActivitySourceLimit.ToString(CultureInfo.InvariantCulture),
        };

    private static JsonArray SystemActivityRequiredArray(
        JsonObject data,
        string primaryKey,
        string fallbackKey)
    {
        if (data.ContainsKey(primaryKey))
        {
            return data[primaryKey] as JsonArray
                ?? throw new InvalidDataException("Invalid system activity list.");
        }
        return data[fallbackKey] as JsonArray
            ?? throw new InvalidDataException("Missing system activity list.");
    }

    private static int? SystemActivityOptionalTotal(JsonObject data)
    {
        var key = data.ContainsKey("total") ? "total" : "total_count";
        if (!data.ContainsKey(key) || data[key] is null)
        {
            return null;
        }
        return data[key] is JsonValue node && node.TryGetValue<int>(out var total) &&
            total >= 0 && total <= SystemActivityMaximumTotal
                ? total
                : throw new InvalidDataException("Invalid system process total.");
    }

    private static IReadOnlyList<NasSystemProcessSummary> ParseSystemProcesses(JsonArray rows)
    {
        var seen = new HashSet<int>();
        var processes = new List<NasSystemProcessSummary>();
        foreach (var node in rows)
        {
            var item = node as JsonObject
                ?? throw new InvalidDataException("Invalid system process item.");
            var processId = SystemActivityProcessId(item);
            var name = SystemActivityDisplayName(item, "name", "process_name");
            if (processId is null || name is null || !seen.Add(processId.Value))
            {
                continue;
            }
            processes.Add(new NasSystemProcessSummary(
                $"process:{processId.Value.ToString(CultureInfo.InvariantCulture)}",
                processId.Value,
                name,
                SystemActivityText(item, 80, "status"),
                SystemActivityGroupId(item, "group_id", "group", "service")));
        }
        return processes
            .OrderBy(item => item.Name, StringComparer.CurrentCultureIgnoreCase)
            .ThenBy(item => item.ProcessId)
            .ToArray();
    }

    private static IReadOnlyList<NasProcessGroupSummary> ParseProcessGroups(JsonArray rows)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var groups = new List<NasProcessGroupSummary>();
        foreach (var node in rows)
        {
            var item = node as JsonObject
                ?? throw new InvalidDataException("Invalid system process group item.");
            var id = SystemActivityGroupId(item, "id", "group_id", "service");
            var name = SystemActivityDisplayName(item, "display_name", "name", "service");
            if (id is null || name is null || !seen.Add(id))
            {
                continue;
            }
            groups.Add(new NasProcessGroupSummary(
                id,
                name,
                SystemActivityText(item, 80, "status"),
                SystemActivityOptionalCount(item, "process_count", "count")));
        }
        return groups
            .OrderBy(item => item.Name, StringComparer.CurrentCultureIgnoreCase)
            .ThenBy(item => item.Id, StringComparer.Ordinal)
            .ToArray();
    }

    private static int? SystemActivityProcessId(JsonObject item)
    {
        foreach (var key in new[] { "pid", "process_id" })
        {
            if (!item.ContainsKey(key) || item[key] is null)
            {
                continue;
            }
            return item[key] is JsonValue node && node.TryGetValue<int>(out var value) && value >= 0
                ? value
                : null;
        }
        return null;
    }

    private static string? SystemActivityDisplayName(JsonObject item, params string[] keys)
    {
        var value = SystemActivityText(item, 512, keys);
        if (value is null)
        {
            return null;
        }
        var components = value.Split(['/', '\\'], StringSplitOptions.RemoveEmptyEntries);
        return SystemActivityNormalizeText(components.LastOrDefault() ?? value, 160);
    }

    private static string? SystemActivityGroupId(JsonObject item, params string[] keys)
    {
        var value = SystemActivityText(item, 128, keys);
        return value is not null && value.All(character =>
            char.IsLetterOrDigit(character) || character is '.' or '_' or '-' or ':')
                ? value
                : null;
    }

    private static string? SystemActivityText(
        JsonObject item,
        int maximumLength,
        params string[] keys)
    {
        foreach (var key in keys)
        {
            if (item[key] is JsonValue node && node.TryGetValue<string>(out var value))
            {
                return SystemActivityNormalizeText(value, maximumLength);
            }
        }
        return null;
    }

    private static string? SystemActivityNormalizeText(string? value, int maximumLength)
    {
        if (value is null)
        {
            return null;
        }
        var normalized = string.Join(' ', value.Split(['\r', '\n']))
            .Trim();
        return string.IsNullOrWhiteSpace(normalized)
            ? null
            : normalized[..Math.Min(normalized.Length, maximumLength)];
    }

    private static int? SystemActivityOptionalCount(JsonObject item, params string[] keys)
    {
        foreach (var key in keys)
        {
            if (!item.ContainsKey(key) || item[key] is null)
            {
                continue;
            }
            return item[key] is JsonValue node && node.TryGetValue<int>(out var count) &&
                count >= 0 && count <= SystemActivityMaximumTotal
                    ? count
                    : null;
        }
        return null;
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

    private bool SupportsStorageAnalysis() =>
        _capabilities.TryGetValue("SYNO.FileStation.List", out var capability) &&
        string.Equals(capability.Name, "SYNO.FileStation.List", StringComparison.Ordinal) &&
        capability.MinVersion <= StorageAnalysisApiVersion &&
        capability.MaxVersion >= StorageAnalysisApiVersion &&
        string.Equals(capability.RequestFormat, "FORM", StringComparison.OrdinalIgnoreCase);

    private async Task<NasDetailsSection<NasStorageAnalysisSummary>> LoadStorageAnalysisSectionAsync(
        CancellationToken cancellationToken)
    {
        if (!SupportsStorageAnalysis())
        {
            return Unavailable<NasStorageAnalysisSummary>(
                "nas-details.storage-analysis.unavailable");
        }
        try
        {
            var shares = await LoadStorageAnalysisSharesAsync(cancellationToken)
                .ConfigureAwait(false);
            var candidates = new List<StorageAnalysisFileCandidate>();
            var partial = shares.IsTruncated;
            foreach (var share in shares.Items.Take(StorageAnalysisShareLimit))
            {
                if (candidates.Count >= StorageAnalysisFileLimit)
                {
                    partial = true;
                    break;
                }
                try
                {
                    var remaining = StorageAnalysisFileLimit - candidates.Count;
                    var files = await LoadStorageAnalysisFilesAsync(
                        share.Path,
                        Math.Min(StorageAnalysisFilesPerShare, remaining),
                        cancellationToken).ConfigureAwait(false);
                    candidates.AddRange(files);
                    if (files.Count >= StorageAnalysisFilesPerShare)
                    {
                        partial = true;
                    }
                }
                catch (OperationCanceledException)
                {
                    throw;
                }
                catch (Exception error) when (IsNasDetailsReadFailure(error))
                {
                    partial = true;
                }
            }

            var summary = BuildStorageAnalysisSummary(
                Math.Min(shares.Items.Count, StorageAnalysisShareLimit),
                candidates,
                partial || shares.Items.Count > StorageAnalysisShareLimit);
            return Available<NasStorageAnalysisSummary>([summary])
                with { IsTruncated = summary.IsPartial };
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception error) when (IsNasDetailsReadFailure(error))
        {
            return Failed<NasStorageAnalysisSummary>(
                "nas-details.storage-analysis.failed");
        }
    }

    private async Task<NasDetailsSection<NasStorageAnalysisSummary>> LoadDeepStorageAnalysisSectionAsync(
        CancellationToken cancellationToken)
    {
        if (!SupportsStorageAnalysis())
        {
            return Unavailable<NasStorageAnalysisSummary>(
                "nas-details.storage-analysis.unavailable");
        }
        try
        {
            var shares = await LoadStorageAnalysisSharesAsync(cancellationToken)
                .ConfigureAwait(false);
            var files = new List<StorageAnalysisFileCandidate>();
            var directories = new Dictionary<string, StorageAnalysisDirectoryAccumulator>(
                StringComparer.Ordinal);
            var folderQueue = new Queue<string>();
            var scannedFolders = 0;
            var skippedFolders = 0;
            var partial = shares.IsTruncated || shares.Items.Count > DeepStorageAnalysisShareLimit;

            foreach (var share in shares.Items.Take(DeepStorageAnalysisShareLimit))
            {
                folderQueue.Enqueue(share.Path);
            }

            while (folderQueue.Count > 0)
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (scannedFolders >= DeepStorageAnalysisFolderLimit ||
                    files.Count >= DeepStorageAnalysisFileLimit)
                {
                    partial = true;
                    skippedFolders += folderQueue.Count;
                    break;
                }

                var folderPath = folderQueue.Dequeue();
                scannedFolders++;
                try
                {
                    var entries = await LoadDeepStorageAnalysisEntriesAsync(
                        folderPath,
                        cancellationToken).ConfigureAwait(false);
                    partial |= entries.IsTruncated;
                    skippedFolders += entries.SkippedFolderCount;
                    foreach (var child in entries.Folders.Take(DeepStorageAnalysisFoldersPerParent))
                    {
                        folderQueue.Enqueue(child);
                    }
                    foreach (var file in entries.Files)
                    {
                        if (files.Count >= DeepStorageAnalysisFileLimit)
                        {
                            partial = true;
                            break;
                        }
                        files.Add(file);
                        AddStorageAnalysisDirectory(directories, folderPath, file);
                    }
                }
                catch (OperationCanceledException)
                {
                    throw;
                }
                catch (Exception error) when (IsNasDetailsReadFailure(error))
                {
                    partial = true;
                    skippedFolders++;
                }
            }

            var duplicateCandidates = await BuildDeepDuplicateCandidatesAsync(
                files,
                cancellationToken).ConfigureAwait(false);
            var directorySummaries = await BuildStorageDirectorySummariesAsync(
                directories,
                cancellationToken).ConfigureAwait(false);

            var summary = BuildStorageAnalysisSummary(
                Math.Min(shares.Items.Count, DeepStorageAnalysisShareLimit),
                files,
                partial,
                fileLimit: DeepStorageAnalysisFileLimit,
                isDeepAnalysis: true,
                scannedFolderCount: scannedFolders,
                skippedFolderCount: skippedFolders,
                directorySummaries: directorySummaries,
                duplicateCandidates: duplicateCandidates);
            return Available<NasStorageAnalysisSummary>([summary])
                with { IsTruncated = summary.IsPartial };
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception error) when (IsNasDetailsReadFailure(error))
        {
            return Failed<NasStorageAnalysisSummary>(
                "nas-details.storage-analysis.failed");
        }
    }

    private async Task<StorageAnalysisSharePage> LoadStorageAnalysisSharesAsync(
        CancellationToken cancellationToken)
    {
        var data = await _api.CallReadJsonObjectAsync(
            _profile,
            _session,
            Required("SYNO.FileStation.List"),
            StorageAnalysisApiVersion,
            "list_share",
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["offset"] = "0",
                ["limit"] = StorageAnalysisShareLimit.ToString(CultureInfo.InvariantCulture),
                ["sort_by"] = "name",
                ["sort_direction"] = "asc",
                ["additional"] = "[\"mount_point_type\",\"perm\"]",
            },
            cancellationToken).ConfigureAwait(false);
        var page = ShareAccessRequiredArray(data, "shares");
        var responseOffset = ShareAccessRequiredNonnegativeInt(data, "offset");
        var total = ShareAccessRequiredNonnegativeInt(data, "total");
        if (responseOffset != 0 || page.Count > StorageAnalysisShareLimit ||
            total < page.Count)
        {
            throw new InvalidDataException("Invalid storage-analysis share page.");
        }

        var shares = new List<StorageAnalysisShare>();
        foreach (var node in page)
        {
            var item = node as JsonObject
                ?? throw new InvalidDataException("Invalid storage-analysis share.");
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
            shares.Add(new StorageAnalysisShare(path, name));
        }
        return new StorageAnalysisSharePage(shares, total > page.Count);
    }

    private async Task<IReadOnlyList<StorageAnalysisFileCandidate>> LoadStorageAnalysisFilesAsync(
        string sharePath,
        int limit,
        CancellationToken cancellationToken)
    {
        if (limit <= 0)
        {
            return [];
        }
        var data = await _api.CallReadJsonObjectAsync(
            _profile,
            _session,
            Required("SYNO.FileStation.List"),
            StorageAnalysisApiVersion,
            "list",
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["folder_path"] = sharePath,
                ["offset"] = "0",
                ["limit"] = limit.ToString(CultureInfo.InvariantCulture),
                ["sort_by"] = "size",
                ["sort_direction"] = "desc",
                ["filetype"] = "file",
                ["additional"] = "[\"size\",\"time\"]",
            },
            cancellationToken).ConfigureAwait(false);
        var files = ShareAccessRequiredArray(data, "files");
        if (files.Count > limit)
        {
            throw new InvalidDataException("Storage-analysis file page exceeded its bound.");
        }
        var result = new List<StorageAnalysisFileCandidate>();
        foreach (var node in files)
        {
            var item = node as JsonObject
                ?? throw new InvalidDataException("Invalid storage-analysis file.");
            if (item.Bool("isdir") == true)
            {
                continue;
            }
            var name = RequiredDisplayString(item, "name")
                ?? RequiredDisplayString(item, "path")?.Split('/').LastOrDefault();
            var size = Nonnegative(item.Long("size") ?? item.Object("additional")?.Long("size"));
            if (string.IsNullOrWhiteSpace(name) || name.Length > 1_024 ||
                name.Any(char.IsControl) || name.Contains('/') || name.Contains('\\') ||
                size is null)
            {
                continue;
            }
            var modified = item.Object("additional")?.Object("time")?.Date("mtime")
                ?? item.Date("mtime");
            result.Add(new StorageAnalysisFileCandidate(
                name,
                size.Value,
                modified,
                Path: null,
                Owner: null,
                AccessedAt: null));
        }
        return result;
    }

    private async Task<DeepStorageAnalysisEntryPage> LoadDeepStorageAnalysisEntriesAsync(
        string folderPath,
        CancellationToken cancellationToken)
    {
        var data = await _api.CallReadJsonObjectAsync(
            _profile,
            _session,
            Required("SYNO.FileStation.List"),
            StorageAnalysisApiVersion,
            "list",
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["folder_path"] = folderPath,
                ["offset"] = "0",
                ["limit"] = Math.Max(
                    DeepStorageAnalysisFilesPerFolder,
                    DeepStorageAnalysisFoldersPerParent).ToString(CultureInfo.InvariantCulture),
                ["sort_by"] = "name",
                ["sort_direction"] = "asc",
                ["additional"] = "[\"size\",\"owner\",\"time\"]",
            },
            cancellationToken).ConfigureAwait(false);
        var items = ShareAccessRequiredArray(data, "files");
        var responseOffset = data.Int("offset") ?? 0;
        var total = data.Int("total") ?? items.Count;
        if (responseOffset != 0 || total < items.Count ||
            items.Count > Math.Max(DeepStorageAnalysisFilesPerFolder, DeepStorageAnalysisFoldersPerParent))
        {
            throw new InvalidDataException("Invalid deep storage-analysis page.");
        }

        var folders = new List<string>();
        var files = new List<StorageAnalysisFileCandidate>();
        var skippedFolders = 0;
        foreach (var node in items)
        {
            var item = node as JsonObject
                ?? throw new InvalidDataException("Invalid deep storage-analysis item.");
            var path = RequiredDisplayString(item, "path");
            var name = RequiredDisplayString(item, "name")
                ?? path?.Split('/').LastOrDefault();
            if (string.IsNullOrWhiteSpace(path) ||
                !path.StartsWith("/", StringComparison.Ordinal) ||
                path.Length > 4_096 ||
                path.Any(char.IsControl) ||
                path.Contains('\\') ||
                string.IsNullOrWhiteSpace(name) ||
                name.Length > 1_024 ||
                name.Any(char.IsControl) ||
                name.Contains('/') ||
                name.Contains('\\') ||
                IsRecycleShare(path, name))
            {
                continue;
            }

            if (item.Bool("isdir") == true)
            {
                if (folders.Count < DeepStorageAnalysisFoldersPerParent)
                {
                    folders.Add(path);
                }
                else
                {
                    skippedFolders++;
                }
                continue;
            }

            var additional = item.Object("additional");
            var size = Nonnegative(item.Long("size") ?? additional?.Long("size"));
            if (size is null)
            {
                continue;
            }
            var time = additional?.Object("time");
            var owner = StorageAnalysisOwner(additional);
            var modified = time?.Date("mtime") ?? item.Date("mtime");
            var accessed = time?.Date("atime") ?? item.Date("atime");
            files.Add(new StorageAnalysisFileCandidate(
                name,
                size.Value,
                modified,
                Path: path,
                Owner: owner,
                AccessedAt: accessed));
        }

        return new DeepStorageAnalysisEntryPage(
            files.Take(DeepStorageAnalysisFilesPerFolder).ToArray(),
            folders,
            skippedFolders,
            total > items.Count ||
                files.Count > DeepStorageAnalysisFilesPerFolder ||
                folders.Count > DeepStorageAnalysisFoldersPerParent ||
                skippedFolders > 0);
    }

    private static NasStorageAnalysisSummary BuildStorageAnalysisSummary(
        int scannedShareCount,
        IReadOnlyList<StorageAnalysisFileCandidate> files,
        bool partial,
        int fileLimit = StorageAnalysisFileLimit,
        bool isDeepAnalysis = false,
        int scannedFolderCount = 0,
        int skippedFolderCount = 0,
        IReadOnlyList<NasStorageDirectorySummary>? directorySummaries = null,
        IReadOnlyList<NasStorageDuplicateCandidate>? duplicateCandidates = null)
    {
        var safeFiles = files.Take(fileLimit).ToArray();
        var categories = safeFiles
            .GroupBy(item => StorageAnalysisCategoryFor(item.Name))
            .Select(group => new NasStorageCategorySummary(
                group.Key,
                group.Count(),
                SumStorageAnalysisBytes(group.Select(item => item.SizeBytes))))
            .OrderByDescending(item => item.SizeBytes)
            .ThenBy(item => item.Category)
            .ToArray();
        var large = safeFiles
            .OrderByDescending(item => item.SizeBytes)
            .ThenBy(item => item.Name, StringComparer.CurrentCultureIgnoreCase)
            .Take(10)
            .Select(item => new NasStorageFileCandidate(
                item.Name,
                item.SizeBytes,
                item.ModifiedAt))
            .ToArray();
        var recent = safeFiles
            .Where(item => item.ModifiedAt is not null)
            .OrderByDescending(item => item.ModifiedAt)
            .ThenBy(item => item.Name, StringComparer.CurrentCultureIgnoreCase)
            .Take(5)
            .Select(item => new NasStorageFileCandidate(
                item.Name,
                item.SizeBytes,
                item.ModifiedAt))
            .ToArray();
        var old = safeFiles
            .Where(item => item.ModifiedAt is not null)
            .OrderBy(item => item.ModifiedAt)
            .ThenBy(item => item.Name, StringComparer.CurrentCultureIgnoreCase)
            .Take(5)
            .Select(item => new NasStorageFileCandidate(
                item.Name,
                item.SizeBytes,
                item.ModifiedAt))
            .ToArray();
        var duplicates = duplicateCandidates ?? BuildNameSizeDuplicateCandidates(safeFiles);
        return new NasStorageAnalysisSummary(
            scannedShareCount,
            safeFiles.Length,
            SumStorageAnalysisBytes(safeFiles.Select(item => item.SizeBytes)),
            partial || files.Count > safeFiles.Length,
            categories,
            large,
            recent,
            old,
            duplicates,
            isDeepAnalysis,
            scannedFolderCount,
            skippedFolderCount,
            isDeepAnalysis ? BuildOwnerSummary(safeFiles) : null,
            isDeepAnalysis ? BuildAccessTimeSummary(safeFiles) : null,
            directorySummaries);
    }

    private async Task<IReadOnlyList<NasStorageDuplicateCandidate>> BuildDeepDuplicateCandidatesAsync(
        IReadOnlyList<StorageAnalysisFileCandidate> files,
        CancellationToken cancellationToken)
    {
        var groups = files
            .Where(item => item.SizeBytes > 0 && item.Path is not null)
            .GroupBy(
                item => (Name: item.Name.ToUpperInvariant(), item.SizeBytes),
                item => item)
            .Where(group => group.Count() > 1)
            .OrderByDescending(group => group.Key.SizeBytes)
            .ThenBy(group => group.Key.Name, StringComparer.CurrentCultureIgnoreCase)
            .Take(DeepStorageAnalysisDuplicateGroupLimit)
            .ToArray();
        var result = new List<NasStorageDuplicateCandidate>();
        foreach (var group in groups)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var confirmedCount = await TryConfirmDuplicateContentAsync(
                group.Take(DeepStorageAnalysisMd5FilesPerGroup).ToArray(),
                cancellationToken).ConfigureAwait(false);
            result.Add(new NasStorageDuplicateCandidate(
                group.First().Name,
                group.Key.SizeBytes,
                confirmedCount ?? group.Count(),
                IsContentConfirmed: confirmedCount is >= 2));
        }
        return result;
    }

    private async Task<int?> TryConfirmDuplicateContentAsync(
        IReadOnlyList<StorageAnalysisFileCandidate> files,
        CancellationToken cancellationToken)
    {
        if (!FileMD5CapabilityAvailable || files.Count < 2)
        {
            return null;
        }

        var digestCounts = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        try
        {
            foreach (var file in files)
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (file.Path is null)
                {
                    continue;
                }
                var digest = await CalculateMD5Async(file.Path, cancellationToken)
                    .ConfigureAwait(false);
                digestCounts[digest] = digestCounts.TryGetValue(digest, out var count)
                    ? count + 1
                    : 1;
            }
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (FileMD5Exception)
        {
            return null;
        }
        catch (Exception error) when (IsNasDetailsReadFailure(error))
        {
            return null;
        }
        return digestCounts.Count == 0 ? null : digestCounts.Values.Max();
    }

    private static IReadOnlyList<NasStorageDuplicateCandidate> BuildNameSizeDuplicateCandidates(
        IReadOnlyList<StorageAnalysisFileCandidate> files) =>
        files
            .Where(item => item.SizeBytes > 0)
            .GroupBy(
                item => (Name: item.Name.ToUpperInvariant(), item.SizeBytes),
                item => item)
            .Where(group => group.Count() > 1)
            .OrderByDescending(group => group.Key.SizeBytes)
            .ThenBy(group => group.Key.Name, StringComparer.CurrentCultureIgnoreCase)
            .Take(5)
            .Select(group => new NasStorageDuplicateCandidate(
                group.First().Name,
                group.Key.SizeBytes,
                group.Count()))
            .ToArray();

    private static NasStorageOwnerSummary BuildOwnerSummary(
        IReadOnlyList<StorageAnalysisFileCandidate> files)
    {
        var owners = files
            .Select(item => item.Owner)
            .Where(owner => !string.IsNullOrWhiteSpace(owner))
            .Select(owner => owner!)
            .ToArray();
        return new NasStorageOwnerSummary(
            owners.Length,
            owners.Distinct(StringComparer.OrdinalIgnoreCase).Count());
    }

    private static NasStorageAccessTimeSummary BuildAccessTimeSummary(
        IReadOnlyList<StorageAnalysisFileCandidate> files)
    {
        var accessTimes = files
            .Select(item => item.AccessedAt)
            .OfType<DateTimeOffset>()
            .OrderBy(item => item)
            .ToArray();
        return new NasStorageAccessTimeSummary(
            accessTimes.Length,
            accessTimes.Length > 0 ? accessTimes[0] : null);
    }

    private static void AddStorageAnalysisDirectory(
        IDictionary<string, StorageAnalysisDirectoryAccumulator> directories,
        string folderPath,
        StorageAnalysisFileCandidate file)
    {
        if (!directories.TryGetValue(folderPath, out var accumulator))
        {
            accumulator = new StorageAnalysisDirectoryAccumulator(
                folderPath,
                SafeStorageAnalysisDirectoryName(folderPath));
            directories[folderPath] = accumulator;
        }
        accumulator.Add(file.SizeBytes);
    }

    private async Task<IReadOnlyList<NasStorageDirectorySummary>> BuildStorageDirectorySummariesAsync(
        IReadOnlyDictionary<string, StorageAnalysisDirectoryAccumulator> directories,
        CancellationToken cancellationToken)
    {
        var candidates = directories.Values
            .OrderByDescending(item => item.SizeBytes)
            .ThenBy(item => item.Name, StringComparer.CurrentCultureIgnoreCase)
            .Take(8)
            .ToArray();
        var results = new List<NasStorageDirectorySummary>();
        var measured = 0;
        foreach (var item in candidates)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var fileCount = item.FileCount;
            var sizeBytes = item.SizeBytes;
            if (DirectorySizeCapabilityAvailable &&
                measured < DeepStorageAnalysisDirectorySizeLimit)
            {
                measured++;
                try
                {
                    var measuredSize = await CalculateDirectorySizeAsync(
                        item.Path,
                        cancellationToken).ConfigureAwait(false);
                    fileCount = (int)Math.Min(int.MaxValue, measuredSize.FileCount);
                    sizeBytes = measuredSize.TotalBytes;
                }
                catch (OperationCanceledException)
                {
                    throw;
                }
                catch (DirectorySizeException)
                {
                }
                catch (Exception error) when (IsNasDetailsReadFailure(error))
                {
                }
            }
            results.Add(new NasStorageDirectorySummary(
                item.Name,
                fileCount,
                sizeBytes));
        }
        return results;
    }

    private static string SafeStorageAnalysisDirectoryName(string path)
    {
        var name = path.Split('/', StringSplitOptions.RemoveEmptyEntries).LastOrDefault();
        return string.IsNullOrWhiteSpace(name) ||
            name.Length > 1_024 ||
            name.Any(char.IsControl)
                ? string.Empty
                : name;
    }

    private static string? StorageAnalysisOwner(JsonObject? additional)
    {
        if (additional is null)
        {
            return null;
        }
        var owner = additional["owner"] switch
        {
            JsonObject ownerObject => ownerObject.String("user"),
            JsonValue => additional.String("owner"),
            _ => null,
        };
        return string.IsNullOrWhiteSpace(owner) || owner.Length > 256 || owner.Any(char.IsControl)
            ? null
            : owner.Trim();
    }

    private static NasStorageAnalysisCategory StorageAnalysisCategoryFor(string name)
    {
        var extension = Path.GetExtension(name).ToLowerInvariant();
        return extension switch
        {
            ".jpg" or ".jpeg" or ".png" or ".gif" or ".heic" or ".heif" or ".webp" or ".tif" or ".tiff" =>
                NasStorageAnalysisCategory.Images,
            ".mov" or ".mp4" or ".m4v" or ".mkv" or ".webm" or ".avi" =>
                NasStorageAnalysisCategory.Videos,
            ".pdf" or ".doc" or ".docx" or ".xls" or ".xlsx" or ".ppt" or ".pptx" or ".txt" or ".md" =>
                NasStorageAnalysisCategory.Documents,
            ".zip" or ".7z" or ".rar" or ".tar" or ".gz" or ".tgz" =>
                NasStorageAnalysisCategory.Archives,
            _ => NasStorageAnalysisCategory.Other,
        };
    }

    private static long SumStorageAnalysisBytes(IEnumerable<long> values)
    {
        try
        {
            var total = 0L;
            foreach (var value in values)
            {
                total = checked(total + Math.Max(0, value));
            }
            return total;
        }
        catch (OverflowException)
        {
            return long.MaxValue;
        }
    }

    private sealed record StorageAnalysisShare(
        string Path,
        string Name);

    private sealed record StorageAnalysisSharePage(
        IReadOnlyList<StorageAnalysisShare> Items,
        bool IsTruncated);

    private sealed record StorageAnalysisFileCandidate(
        string Name,
        long SizeBytes,
        DateTimeOffset? ModifiedAt,
        string? Path = null,
        string? Owner = null,
        DateTimeOffset? AccessedAt = null);

    private sealed record DeepStorageAnalysisEntryPage(
        IReadOnlyList<StorageAnalysisFileCandidate> Files,
        IReadOnlyList<string> Folders,
        int SkippedFolderCount,
        bool IsTruncated);

    private sealed class StorageAnalysisDirectoryAccumulator(string path, string name)
    {
        public string Path { get; } = path;
        public string Name { get; } = name;
        public int FileCount { get; private set; }
        public long SizeBytes { get; private set; }

        public void Add(long sizeBytes)
        {
            FileCount++;
            SizeBytes = SumStorageAnalysisBytes([SizeBytes, sizeBytes]);
        }
    }

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
