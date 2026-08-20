using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmApiClient
{
    public async Task<DsmSession> LoginAsync(
        NasProfile profile,
        string password,
        string? otp,
        CancellationToken cancellationToken = default) =>
        await LoginAsync(
            profile,
            password,
            otp,
            DsmConnectionSource.DirectAddress,
            cancellationToken).ConfigureAwait(false);

    public async Task<DsmSession> LoginAsync(
        NasProfile profile,
        string password,
        string? otp,
        DsmConnectionSource source,
        CancellationToken cancellationToken = default)
    {
        var parameters = new Dictionary<string, string>
        {
            ["api"] = "SYNO.API.Auth",
            ["version"] = "7",
            ["method"] = "login",
            ["account"] = profile.Username,
            ["passwd"] = password,
            ["session"] = "FileStation",
            ["format"] = "sid",
            ["enable_syno_token"] = "yes",
            ["enable_device_token"] = "yes",
            ["device_name"] = "LanStash Windows",
        };
        if (!string.IsNullOrWhiteSpace(otp))
        {
            parameters["otp_code"] = otp.Trim();
        }
        var data = await PostAsync(
            profile,
            "/webapi/auth.cgi",
            parameters,
            session: null,
            source: source,
            cancellationToken: cancellationToken).ConfigureAwait(false);
        var sid = data["sid"]?.GetValue<string>();
        if (string.IsNullOrWhiteSpace(sid))
        {
            throw new DsmException(
                UserText.Key("WinSharedab4ce8cd180797fc"),
                UserText.Key("WinSharedc144a2dc9ace5c1f"),
                authenticationFailure: true);
        }
        return new DsmSession(
            profile.Id,
            sid,
            data["synotoken"]?.GetValue<string>(),
            data["did"]?.GetValue<string>());
    }

    public async Task LogoutAsync(
        NasProfile profile,
        DsmSession session,
        CancellationToken cancellationToken = default)
    {
        try
        {
            await PostAsync(
                profile,
                "/webapi/auth.cgi",
                new Dictionary<string, string>
                {
                    ["api"] = "SYNO.API.Auth",
                    ["version"] = "7",
                    ["method"] = "logout",
                    ["session"] = "FileStation",
                },
                session,
                cancellationToken).ConfigureAwait(false);
        }
        catch (DsmException)
        {
            // 本机仍应清除会话，远端退出失败不阻塞用户。
        }
    }
}
