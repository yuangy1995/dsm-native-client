using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public async Task<IReadOnlyList<NasTaskEntry>> LoadScheduledTasksAsync(CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var capability = RequireTaskRead("SYNO.Core.TaskScheduler", 3);
        var data = await _api.CallReadJsonObjectAsync(_profile, _session, capability, 3, "list",
            new Dictionary<string, string> { ["start"] = "0", ["limit"] = "1000" }, cancellationToken).ConfigureAwait(false);
        if (data["tasks"] is not JsonArray rows || rows.Count >= 1000) throw InvalidNasServiceSettings();
        var result = new List<NasTaskEntry>(); var identities = new HashSet<(int, string?)>();
        foreach (var node in rows)
        {
            if (node is not JsonObject item || TaskInteger(item["id"]) is not int id || id < 0) throw InvalidNasServiceSettings();
            var name = DirectoryText(item["name"]); var realOwner = DirectoryText(item["real_owner"]);
            if (!StableTaskName(name) || !identities.Add((id, string.IsNullOrEmpty(realOwner) ? null : realOwner))) throw InvalidNasServiceSettings();
            result.Add(new(id, name!, DirectoryText(item["owner"]), realOwner, DirectoryText(item["type"]), DirectoryText(item["action"]),
                DirectoryBoolean(item["enable"]), DirectoryText(item["next_trigger_time"]), DirectoryBoolean(item["can_run"]), DirectoryBoolean(item["can_edit"])));
        }
        return result.AsReadOnly();
    }
    public async Task<NasTaskDetail> LoadScheduledTaskDetailAsync(int? id, string? realOwner = null, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (realOwner == "") realOwner = null;
        if (id is < 0 || realOwner is not null && !StableTaskName(realOwner)) throw InvalidNasServiceSettings();
        var capability = RequireTaskRead("SYNO.Core.TaskScheduler", 4);
        var parameters = new Dictionary<string, string> { ["id"] = (id ?? -1).ToString(CultureInfo.InvariantCulture) };
        if (realOwner is not null) parameters["real_owner"] = TaskReadText(capability, realOwner);
        if (id is null) parameters["type"] = TaskReadText(capability, "script");
        var data = await _api.CallReadJsonObjectAsync(_profile, _session, capability, 4, "get", parameters, cancellationToken).ConfigureAwait(false);
        if (data["id"] is not null && TaskInteger(data["id"]) != (id ?? -1)) throw InvalidNasServiceSettings();
        var schedule = OptionalTaskObject(data["schedule"]); var extra = OptionalTaskObject(data["extra"]);
        var reportedOwner = DirectoryText(data["real_owner"]);
        if (realOwner is not null && reportedOwner is not null && realOwner != reportedOwner) throw InvalidNasServiceSettings();
        return new(id, realOwner, DirectoryText(data["name"]), DirectoryText(data["owner"]), reportedOwner, DirectoryBoolean(data["enable"]),
            schedule is null ? null : new(TaskInteger(schedule["date_type"]), DirectoryText(schedule["week_day"]), DirectoryText(schedule["date"]),
                TaskInteger(schedule["repeat_date"]), TaskIntegerArray(schedule["monthly_week"]), TaskInteger(schedule["hour"]), TaskInteger(schedule["minute"]),
                TaskInteger(schedule["repeat_hour"]), TaskInteger(schedule["repeat_min"]), TaskInteger(schedule["last_work_hour"])),
            DirectoryText(extra?["script"]), DirectoryBoolean(extra?["notify_if_error"]), DirectoryText(extra?["notify_mail"]));
    }
    public async Task<IReadOnlyList<NasTaskResult>> LoadScheduledTaskResultsAsync(string taskName, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!StableTaskName(taskName)) throw InvalidNasServiceSettings();
        var capability = RequireTaskRead("SYNO.Core.EventScheduler", 1);
        var data = await _api.CallReadJsonObjectAsync(_profile, _session, capability, 1, "result_list",
            new Dictionary<string, string> { ["task_name"] = TaskReadText(capability, taskName) }, cancellationToken).ConfigureAwait(false);
        if (data["results"] is not JsonArray rows) throw InvalidNasServiceSettings();
        var result = new List<NasTaskResult>(); var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var node in rows)
        {
            if (node is not JsonObject item) throw InvalidNasServiceSettings();
            var id = DirectoryText(TaskCoalesce(item["result_id"], item["id"])); var reportedName = DirectoryText(item["task_name"]);
            if (!StableTaskName(id) || !seen.Add(id!) || reportedName is not null && reportedName != taskName) throw InvalidNasServiceSettings();
            var exit = OptionalTaskObject(item["exit_info"]);
            result.Add(new(id!, reportedName ?? taskName, DirectoryText(item["start_time"]), DirectoryText(item["stop_time"]),
                DirectoryText(TaskCoalesce(exit?["exit_type"], item["exit_type"])), TaskInteger(TaskCoalesce(exit?["exit_code"], item["exit_code"])), DirectoryText(item["trigger_event"])));
        }
        result.Reverse(); return result.AsReadOnly();
    }
    public async Task<NasTaskResultOutput> LoadScheduledTaskOutputAsync(string taskName, string resultId, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!StableTaskName(taskName) || !StableTaskName(resultId)) throw InvalidNasServiceSettings();
        var capability = RequireTaskRead("SYNO.Core.EventScheduler", 1);
        var data = await _api.CallReadJsonObjectAsync(_profile, _session, capability, 1, "result_get_file", new Dictionary<string, string>
        { ["task_name"] = TaskReadText(capability, taskName), ["result_id"] = TaskReadText(capability, resultId) }, cancellationToken).ConfigureAwait(false);
        return new(DirectoryText(data["script_in"]), DirectoryText(data["script_out"]));
    }
    private ApiCapability RequireTaskRead(string name, int version) => SecurityCapability(name, version) ??
        throw new DsmException(UserText.Key("NasSettingsLoadError"), UserText.Key("NasSettingsUnavailable"), 102);
    private static bool StableTaskName(string? value) => !string.IsNullOrWhiteSpace(value) && !value.Any(char.IsControl);
    private static string TaskReadText(ApiCapability capability, string value) => capability.RequestFormat.Equals("JSON", StringComparison.OrdinalIgnoreCase) ? JsonSerializer.Serialize(value) : value;
    private static int? TaskInteger(JsonNode? value) => value is null ? null : value is JsonValue scalar && scalar.TryGetValue<int>(out var number) ? number : throw InvalidNasServiceSettings();
    private static JsonObject? OptionalTaskObject(JsonNode? value) => value is null ? null : value as JsonObject ?? throw InvalidNasServiceSettings();
    private static IReadOnlyList<int>? TaskIntegerArray(JsonNode? value) => value is null ? null : value is JsonArray array
        ? Array.AsReadOnly(array.Select(item => TaskInteger(item) ?? throw InvalidNasServiceSettings()).ToArray()) : throw InvalidNasServiceSettings();
    private static JsonNode? TaskCoalesce(JsonNode? first, JsonNode? second)
    { if (first is not null && second is not null && !JsonNode.DeepEquals(first, second)) throw InvalidNasServiceSettings(); return first ?? second; }
}
