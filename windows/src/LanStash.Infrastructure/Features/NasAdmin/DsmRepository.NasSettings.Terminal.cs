using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    // DSM 内部接口，仅采用已记录的读取契约，不将失败转换为关闭状态。
    public async Task<NasTerminalSettings> LoadTerminalSettingsAsync(
        CancellationToken cancellationToken = default)
    {
        var data = await ReadNasServiceSettingsAsync("SYNO.Core.Terminal", 3, cancellationToken)
            .ConfigureAwait(false);
        return ParseNasTerminalSettings(data);
    }

    private static NasTerminalSettings ParseNasTerminalSettings(System.Text.Json.Nodes.JsonObject data)
    {
        if (data.Bool("enable_ssh") is not bool ssh || data.Bool("enable_telnet") is not bool telnet)
        {
            throw InvalidNasServiceSettings();
        }

        // 契约未提供 Telnet 端口，SSH 端口缺失或无效时不猜测默认值。
        var port = data.Int("ssh_port");
        return new NasTerminalSettings(ssh, port is > 0 and <= 65535 ? port : null, telnet, null);
    }

    public Task<MutationResult> SaveTerminalSettingsAsync(
        NasTerminalSettings settings,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(settings);
        // 完成基线绑定、确认和逐字段回读前不保留可被总开关意外启用的猜测写请求。
        return Task.FromResult(UnsupportedResult("saveTerminal"));
    }
}
