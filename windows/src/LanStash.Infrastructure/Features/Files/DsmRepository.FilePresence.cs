using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public async Task<FilePresence> ProbeFilePresenceAsync(string path, CancellationToken cancellationToken = default)
        => await ReadFileInfoRowAsync(path, null, cancellationToken).ConfigureAwait(false) is null ? FilePresence.Missing : FilePresence.Present;

    public async Task<FileEntryMetadata?> ReadFileMetadataAsync(string path, CancellationToken cancellationToken = default)
    {
        var row = await ReadFileInfoRowAsync(path, "[\"size\",\"time\",\"perm\",\"type\",\"mount_point_type\"]", cancellationToken).ConfigureAwait(false);
        if (row is null) return null;
        if (row["additional"] is not JsonObject additional) throw new InvalidDataException("file.metadata.invalid_response");
        _ = NativeBool(row, "isdir", out var directory);
        var size = 0L;
        if (!directory && (!NativeLong(row, "size", out size) && !NativeLong(additional, "size", out size) || size < 0))
            throw new InvalidDataException("file.metadata.invalid_size");
        var permission = FileStationPermissions.Parse(additional["perm"]);
        foreach (var key in new[] { "type", "mount_point_type" })
            if (additional[key] is not null && NativeString(additional, key) is null) throw new InvalidDataException("file.metadata.invalid_type");
        return new(new(path, NativeString(row, "name")!, directory, size, OptionalMutationTime(row, additional), null,
            permission.Write ?? false, permission.Delete ?? false), NativeString(additional, "type"), NativeString(additional, "mount_point_type"));
    }

    private async Task<JsonObject?> ReadFileInfoRowAsync(string path, string? additional, CancellationToken cancellationToken)
    {
        if (!ValidMutationObjectPath(path)) throw new ArgumentException("file.presence.invalid_path", nameof(path));
        if (!_capabilities.TryGetValue("SYNO.FileStation.List", out var capability) ||
            capability.Name != "SYNO.FileStation.List" || capability.MinVersion > 2 || capability.MaxVersion < 2)
            throw new NotSupportedException("file.presence.unsupported");
        var parameters = new Dictionary<string, string> { ["path"] = JsonSerializer.Serialize(new[] { path }) };
        if (additional is not null) parameters["additional"] = additional;
        var data = await _api.CallReadJsonObjectAsync(_profile, _session, capability, 2, "getinfo", parameters, cancellationToken).ConfigureAwait(false);
        if (data["files"] is not JsonArray { Count: 1 } files || files[0] is not JsonObject row || NativeString(row, "path") != path)
            throw new InvalidDataException("file.presence.invalid_response");
        if (row.ContainsKey("code"))
        {
            if (!NativeLong(row, "code", out var code) || code < 0 || code > int.MaxValue)
                throw new InvalidDataException("file.presence.invalid_code");
            if (code == 408) return null;
            if (code != 0) throw new DsmException(UserText.Key("CloudDriveGenericError"), UserText.Key("CloudDriveGenericError"),
                (int)code, authenticationFailure: code is 106 or 107 or 119);
        }
        if (!NativeBool(row, "isdir", out _) || NativeString(row, "name") is not { Length: > 0 } name ||
            !path.EndsWith("/" + name, StringComparison.Ordinal))
            throw new InvalidDataException("file.presence.invalid_item");
        return row;
    }
}
