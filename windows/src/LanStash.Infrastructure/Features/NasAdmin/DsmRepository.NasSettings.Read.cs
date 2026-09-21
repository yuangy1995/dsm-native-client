using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    // 仅使用已记录 NAS 设置的版本交集和 get，不探测猜测方法。
    private Task<JsonObject> ReadNasServiceSettingsAsync(
        string apiName, int maximumVersion, CancellationToken cancellationToken, int minimumVersion = 1)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!_capabilities.TryGetValue(apiName, out var capability) ||
            capability.Name != apiName ||
            capability.MinVersion < 1 || capability.MinVersion > maximumVersion ||
            capability.MaxVersion < minimumVersion ||
            capability.MaxVersion < capability.MinVersion ||
            !(string.Equals(capability.RequestFormat, "FORM", StringComparison.OrdinalIgnoreCase) ||
              string.Equals(capability.RequestFormat, "JSON", StringComparison.OrdinalIgnoreCase)))
        {
            throw new DsmException(UserText.Key("NasSettingsLoadError"),
                UserText.Key("WinShared371d84f48836296f"), 102);
        }

        return _api.CallReadJsonObjectAsync(_profile, _session, capability,
            Math.Min(maximumVersion, capability.MaxVersion), "get",
            cancellationToken: cancellationToken);
    }

    private static DsmException InvalidNasServiceSettings() =>
        new(UserText.Key("NasSettingsLoadError"), UserText.Key("WinShared4470548cdf9d51c2"));
}
