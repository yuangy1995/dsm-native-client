using System.Text.Json.Nodes;

namespace LanStash.Infrastructure;

internal readonly record struct FileStationPermissionValues(bool? Read, bool? Write, bool? Delete);

/// 对齐已记录的 ACL/adv_right 结构；明确 false 不能被另一个分支的 true 覆盖。
internal static class FileStationPermissions
{
    internal static FileStationPermissionValues Parse(JsonNode? node)
    {
        if (node is null) return default;
        if (node is not JsonObject permission) throw Invalid();
        var aclMode = ReadBool(permission, "is_acl_mode");
        var acl = ReadRights(permission, "acl");
        var advanced = ReadRights(permission, "adv_right");
        if (aclMode == true)
            return new(ReadBool(acl, "read") ?? ReadBool(advanced, "read") ?? ReadBool(advanced, "download"),
                ReadBool(acl, "write") ?? ReadBool(advanced, "write") ?? ReadBool(advanced, "upload"),
                ReadBool(acl, "del") ?? ReadBool(advanced, "delete"));
        if (advanced is not null)
            return new(ReadBool(advanced, "read") ?? ReadBool(advanced, "download"),
                ReadBool(advanced, "write") ?? ReadBool(advanced, "upload"), ReadBool(advanced, "delete"));
        // 保留原有直接布尔结构，但不能在明确 ACL 模式缺失权限时借此扩大授权。
        return new(ReadBool(permission, "read"), ReadBool(permission, "write"), ReadBool(permission, "delete"));
    }

    private static JsonObject? ReadRights(JsonObject permission, string key)
    {
        if (permission[key] is null) return null;
        if (permission[key] is not JsonObject rights || rights.Any(pair => pair.Value is not JsonValue value || !value.TryGetValue<bool>(out _)))
            throw Invalid();
        return rights;
    }
    private static bool? ReadBool(JsonObject? values, string key)
    {
        if (values?[key] is null) return null;
        if (values[key] is JsonValue value && value.TryGetValue<bool>(out var result)) return result;
        throw Invalid();
    }
    private static InvalidDataException Invalid() => new("file.permissions.invalid_response");
}
