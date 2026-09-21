using System.Net;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmApiClient
{
    // 仅限制控制台启动 HTML，不限制 VNC 图像流或用户文件。
    public const int MaximumConsoleDocumentBytes = 4 * 1024 * 1024;
    public bool CanReadConsoleDocument => true;
    public async Task<VirtualMachineConsoleDocument> ReadConsoleDocumentAsync(NasProfile profile, DsmSession session,
        VirtualMachineConsolePolicy policy, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(policy);
        if (profile.Id != session.ProfileId || !VirtualMachineConsoleSession.ValidCookie(session.Sid) ||
            !string.IsNullOrWhiteSpace(session.SynoToken) && !VirtualMachineConsoleSession.ValidCookie(session.SynoToken) || !policy.MatchesOrigin(GetBaseUri(profile)))
            throw new InvalidOperationException("vm.console.session_origin");
        using var request = new HttpRequestMessage(HttpMethod.Get, policy.NavigationUri);
        request.Headers.Accept.ParseAdd("text/html");
        request.Headers.UserAgent.ParseAdd("LanStash-Windows/0.1");
        request.Headers.Add("Cookie", $"id={session.Sid}");
        if (!string.IsNullOrWhiteSpace(session.SynoToken)) request.Headers.Add("X-SYNO-TOKEN", session.SynoToken);
        SetNasConnectionContext(request, profile);
        // 生产连接的既有 WindowsCertificateTrustHandler 禁止自动重定向；不另建绕过校验的客户端。
        using var response = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken).ConfigureAwait(false);
        if (response.StatusCode != HttpStatusCode.OK || response.RequestMessage?.RequestUri is not { } final || !policy.AllowsNavigation(final))
            throw new DsmException(UserText.Key("VmConsoleLoadFailed"), UserText.Key("VmConsoleReconnect"), (int)response.StatusCode,
                response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden);
        if (!string.Equals(response.Content.Headers.ContentType?.MediaType, "text/html", StringComparison.OrdinalIgnoreCase))
            throw new DsmBinaryResponseException(DsmBinaryResponseFailure.UnexpectedMediaType, "vm.console.document_type");
        var serverPolicy = response.Headers.TryGetValues("Content-Security-Policy", out var policies) ? string.Join(", ", policies) : null;
        if (serverPolicy?.IndexOfAny(['\r', '\n', '\0']) >= 0) throw new InvalidOperationException("vm.console.document_policy");
        var data = await ReadBoundedBinaryContentAsync(response.Content, "text/html", MaximumConsoleDocumentBytes, cancellationToken).ConfigureAwait(false);
        return new(data.Bytes, serverPolicy, response.Content.Headers.ContentType!.ToString());
    }
}
