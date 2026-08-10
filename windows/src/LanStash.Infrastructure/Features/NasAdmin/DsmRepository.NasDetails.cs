using System.Globalization;
using System.IO;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private const int NasDetailsPageLimit = 50;

    NasDetailsAvailability INasDetailsRepository.Availability => NasDetailsAvailability;

    private NasDetailsAvailability NasDetailsAvailability
    {
        get
        {
            var features = new HashSet<NasDetailsReadFeature>();
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
        return new NasDetailsSnapshot(
            _profile.Id,
            await LoadPackagesSectionAsync(cancellationToken).ConfigureAwait(false),
            await LoadScheduledTasksSectionAsync(cancellationToken).ConfigureAwait(false),
            await LoadLogsSectionAsync(cancellationToken).ConfigureAwait(false),
            await LoadConnectionsSectionAsync(cancellationToken).ConfigureAwait(false));
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
}
