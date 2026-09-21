using System.Globalization;
using LanStash.Domain;

namespace LanStash.App.Features.NasAdmin;

// 仅将表单输入转换为已记录字段，不猜测缺失端口，不让数字控件静默钳制错误输入。
public static class NasServiceSettingsInput
{
    public static bool TryTerminal(NasTerminalSettings baseline, bool ssh, string port, bool telnet,
        out NasTerminalSettings value)
    {
        value = baseline;
        int? sshPort = null;
        if (baseline.SshPort is not null)
        {
            if (!TryPort(port, out var parsed)) return false;
            sshPort = parsed;
        }
        value = new(ssh, sshPort, telnet, null);
        return true;
    }

    public static bool TryProxy(NasProxySettings baseline, bool enabled, string host, string port,
        out NasProxySettings value)
    {
        value = baseline;
        if (!enabled)
        {
            // 停用仅更改开关，不将保留地址/端口当成变化字段。
            value = baseline with { Enabled = false };
            return true;
        }
        var normalized = host.Trim();
        if (normalized.Length == 0 || normalized.Any(char.IsWhiteSpace) ||
            normalized.IndexOfAny(['/', '\\', '?', '#', '@']) >= 0 ||
            Uri.CheckHostName(normalized) == UriHostNameType.Unknown ||
            !TryPort(port, out var parsed)) return false;
        value = new(true, normalized, parsed);
        return true;
    }

    private static bool TryPort(string text, out int port) =>
        int.TryParse(text, NumberStyles.None, CultureInfo.CurrentCulture, out port) &&
        port is >= 1 and <= 65535;
}
