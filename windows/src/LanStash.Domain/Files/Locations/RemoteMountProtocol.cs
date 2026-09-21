using System.Net;

namespace LanStash.Domain;

public enum RemoteMountNfsVersion { V3, V4 }
public enum RemoteMountNfsTransport { Tcp, Udp }
public enum RemoteMountInputIssue { None, InvalidTarget, UnsupportedProtocol, ReadOnlyNotSupported, InvalidAccount, InvalidNfsOptions }

public sealed record RemoteMountConnection(Guid ProfileId, string MountPoint, string RemoteSource, FileRemoteProtocol Protocol, bool? AutomaticMount)
{
    public override string ToString() => nameof(RemoteMountConnection);
}

public sealed record RemoteMountInventory(Guid ProfileId, bool RemoteMountingEnabled, IReadOnlyList<RemoteMountConnection> Items)
{
    public override string ToString() => nameof(RemoteMountInventory);
}

public static class RemoteMountProtocol
{
    public static bool IsMountPoint(string? path) => !string.IsNullOrWhiteSpace(path) && path.Length <= 4096 && path.StartsWith('/') && path != "/" &&
        !path.EndsWith('/') && !path.Contains("//", StringComparison.Ordinal) && !path.Contains('\\') && !path.Any(char.IsControl) &&
        !path.Split('/').Any(part => part is "." or "..");

    public static bool TryBuildConnect(RemoteMountDraft draft, out IReadOnlyDictionary<string, string> parameters, out RemoteMountInputIssue issue)
    {
        parameters = new Dictionary<string, string>(); issue = RemoteMountInputIssue.InvalidTarget;
        if (draft is null || !IsMountPoint(draft.MountPoint) || !TrySource(draft.Server, draft.RemotePath, draft.Protocol, out var source)) return false;
        if (draft.Protocol is not (FileRemoteProtocol.Cifs or FileRemoteProtocol.Nfs)) { issue = RemoteMountInputIssue.UnsupportedProtocol; return false; }
        // 官方表单没有强制只读参数，不能静默丢弃调用方的只读要求。
        if (draft.ReadOnly) { issue = RemoteMountInputIssue.ReadOnlyNotSupported; return false; }
        var values = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["mount_type"] = draft.Protocol == FileRemoteProtocol.Cifs ? "CIFS" : "NFS", ["server_ip"] = source,
            ["mount_point"] = draft.MountPoint, ["user_set"] = "true", ["auto_mount"] = "false"
        };
        if (draft.Protocol == FileRemoteProtocol.Cifs)
        {
            var account = draft.Username ?? ""; var domain = draft.Domain ?? "";
            if (account.Any(char.IsControl) || domain.Any(char.IsControl) || account.Length > 256 || domain.Length > 128 ||
                domain.IndexOfAny(['/', '\\', '@']) >= 0 || domain.Length > 0 && (account.Length == 0 || account.IndexOfAny(['\\', '@']) >= 0))
            { issue = RemoteMountInputIssue.InvalidAccount; return false; }
            values["account"] = domain.Length == 0 ? account : domain + "\\" + account;
            values["passwd"] = draft.Password ?? "";
        }
        else
        {
            if (!Enum.IsDefined(draft.NfsVersion) || !Enum.IsDefined(draft.NfsTransport) ||
                draft.NfsVersion == RemoteMountNfsVersion.V4 && draft.NfsTransport != RemoteMountNfsTransport.Tcp)
            { issue = RemoteMountInputIssue.InvalidNfsOptions; return false; }
            if (!string.IsNullOrEmpty(draft.Username) || !string.IsNullOrEmpty(draft.Password) || !string.IsNullOrEmpty(draft.Domain))
            { issue = RemoteMountInputIssue.InvalidAccount; return false; }
            values["nfs_version"] = draft.NfsVersion == RemoteMountNfsVersion.V3 ? "3" : "4";
            values["protocol"] = draft.NfsTransport == RemoteMountNfsTransport.Tcp ? "tcp" : "udp";
        }
        parameters = values; issue = RemoteMountInputIssue.None; return true;
    }

    private static bool TrySource(string server, string path, FileRemoteProtocol protocol, out string source)
    {
        source = "";
        if (string.IsNullOrWhiteSpace(server) || server.Length > 256 || server.Any(character => char.IsWhiteSpace(character) || char.IsControl(character)) ||
            server.IndexOfAny(['/', '\\', '@', '?', '#']) >= 0 || Uri.CheckHostName(server) == UriHostNameType.Unknown ||
            server.Equals("localhost", StringComparison.OrdinalIgnoreCase) || IPAddress.TryParse(server.Trim('[', ']'), out var address) && IPAddress.IsLoopback(address)) return false;
        if (string.IsNullOrWhiteSpace(path) || path.Length > 4096 || path.Any(char.IsControl) || path.StartsWith("//", StringComparison.Ordinal) || path.StartsWith("\\\\", StringComparison.Ordinal)) return false;
        var normalized = protocol == FileRemoteProtocol.Cifs ? path.Replace('\\', '/') : path;
        normalized = normalized.TrimStart('/');
        if (normalized.Length == 0 || normalized.Contains("//", StringComparison.Ordinal) || normalized.Contains('\\') ||
            normalized.Split('/').Any(part => part is "." or "..")) return false;
        source = protocol == FileRemoteProtocol.Cifs ? $"//{server}/{normalized}" : $"{server}:/{normalized}";
        return true;
    }

    public static bool TryNormalizeSource(string source, FileRemoteProtocol protocol, out string normalized)
    {
        normalized = "";
        if (string.IsNullOrWhiteSpace(source) || protocol is not (FileRemoteProtocol.Cifs or FileRemoteProtocol.Nfs)) return false;
        var value = protocol == FileRemoteProtocol.Cifs ? source.Replace('\\', '/') : source;
        if (protocol == FileRemoteProtocol.Cifs && !value.StartsWith("//", StringComparison.Ordinal)) return false;
        var separator = protocol == FileRemoteProtocol.Cifs ? value.IndexOf('/', 2) : value.IndexOf(":/", StringComparison.Ordinal);
        if (separator < 0 || protocol == FileRemoteProtocol.Cifs && !value.StartsWith("//", StringComparison.Ordinal)) return false;
        var host = protocol == FileRemoteProtocol.Cifs ? value[2..separator] : value[..separator];
        var path = value[(separator + (protocol == FileRemoteProtocol.Cifs ? 1 : 2))..];
        return TrySource(host.ToLowerInvariant(), path, protocol, out normalized);
    }
}
