using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed record DiscoveredConnection(
    NasProfile Profile,
    IReadOnlyDictionary<string, ApiCapability> Capabilities,
    DsmConnectionSource Source = DsmConnectionSource.DirectAddress);

/// <summary>
/// 登录前只使用不含凭据的能力发现探测连接候选。
/// 找到可信连接后，调用方才可以提交账号、密码和验证码。
/// </summary>
public sealed class DsmConnectionResolver(
    IDsmApiClient api,
    DsmQuickConnectResolver quickConnect)
{
    public async Task<DiscoveredConnection> DiscoverAsync(
        NasProfile profile,
        Action<string>? updateStatus = null,
        CancellationToken cancellationToken = default)
    {
        var parsed = NasAddressParser.Parse(profile.Host, profile.Port);
        if (parsed.Kind == NasAddressKind.Direct)
        {
            updateStatus?.Invoke(UserText.Key("WinShareda6d7b48863714f5e"));
            var directProfile = profile with { Host = parsed.Host, Port = parsed.Port };
            return new(
                directProfile,
                await api.DiscoverAsync(
                    directProfile,
                    DsmConnectionSource.DirectAddress,
                    cancellationToken),
                DsmConnectionSource.DirectAddress);
        }

        updateStatus?.Invoke(UserText.Key("WinSharedaa0582cad267718e"));
        IReadOnlyList<QuickConnectEndpoint> endpoints;
        try
        {
            endpoints = await quickConnect.ResolveAsync(parsed.Host, cancellationToken);
        }
        catch (DsmException error) when (
            error.Kind == DsmErrorKind.QuickConnectDirectUnavailable)
        {
            endpoints = [];
        }

        DsmException? lastDirectError = null;
        foreach (var endpoint in endpoints)
        {
            updateStatus?.Invoke(endpoint.Kind == QuickConnectEndpointKind.Local
                ? UserText.Key("WinShared3b38866d76d21239")
                : UserText.Key("WinShared307e0c332a164ea1"));
            var connectionProfile = profile with
            {
                Host = endpoint.Host,
                Port = profile.Port ?? endpoint.Port,
            };
            try
            {
                return new(
                    connectionProfile,
                    await api.DiscoverAsync(
                        connectionProfile,
                        ConnectionSourceFor(endpoint.Kind),
                        cancellationToken),
                    ConnectionSourceFor(endpoint.Kind));
            }
            catch (DsmException error)
            {
                lastDirectError = error;
            }
        }

        updateStatus?.Invoke(UserText.Key("WinShared6edbda7d2a81743a"));
        try
        {
            var relay = await quickConnect.RequestRelayAsync(parsed.Host, cancellationToken);
            var relayProfile = profile with { Host = relay.Host, Port = relay.Port };
            return new(
                relayProfile,
                await api.DiscoverAsync(
                    relayProfile,
                    DsmConnectionSource.QuickConnectRelay,
                    cancellationToken),
                DsmConnectionSource.QuickConnectRelay);
        }
        catch (DsmException error) when (
            error.Kind == DsmErrorKind.QuickConnectRelayUnavailable &&
            lastDirectError is not null)
        {
            throw lastDirectError;
        }
    }

    internal static DsmConnectionSource ConnectionSourceFor(
        QuickConnectEndpointKind endpointKind) => endpointKind switch
        {
            QuickConnectEndpointKind.Local => DsmConnectionSource.QuickConnectLan,
            QuickConnectEndpointKind.External => DsmConnectionSource.QuickConnectExternal,
            QuickConnectEndpointKind.Relay => DsmConnectionSource.QuickConnectRelay,
            _ => throw new ArgumentOutOfRangeException(nameof(endpointKind)),
        };
}
