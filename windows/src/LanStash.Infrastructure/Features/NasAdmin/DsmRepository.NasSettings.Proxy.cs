using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    // DSM 内部接口，仅采用已记录的读取契约，不将失败转换为关闭状态。
    public async Task<NasProxySettings> LoadProxySettingsAsync(
        CancellationToken cancellationToken = default)
    {
        var data = await ReadNasServiceSettingsAsync("SYNO.Core.Network.Proxy", 1, cancellationToken)
            .ConfigureAwait(false);
        return ParseNasProxySettings(data);
    }

    private static NasProxySettings ParseNasProxySettings(System.Text.Json.Nodes.JsonObject data)
    {
        if (data.Bool("enable") is not bool enabled)
        {
            throw InvalidNasServiceSettings();
        }

        var port = data.Int("http_port");
        return new NasProxySettings(enabled, data.String("http_host"),
            port is > 0 and <= 65535 ? port : null);
    }

    public Task<MutationResult> SaveProxySettingsAsync(
        NasProxySettings settings,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(settings);
        // 完成基线绑定、确认和逐字段回读前不保留可被总开关意外启用的猜测写请求。
        return Task.FromResult(UnsupportedResult("saveProxy"));
    }
}
