using System.Net;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmApiClient
{
    public bool CanReadConsoleAssets => true;
    public const int MaximumConsoleAssetBytes = 16 * 1024 * 1024;
    public async Task<VirtualMachineConsoleDocument> ReadConsoleAssetAsync(NasProfile profile, DsmSession session,
        VirtualMachineConsolePolicy policy, Uri resource, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(policy);
        var expectedType = policy.ManagedAssetMediaType(resource);
        if (profile.Id == Guid.Empty || profile.Id != session.ProfileId || !policy.MatchesOrigin(GetBaseUri(profile)) || expectedType is null ||
            !VirtualMachineConsoleSession.ValidCookie(session.Sid) ||
            !string.IsNullOrWhiteSpace(session.SynoToken) && !VirtualMachineConsoleSession.ValidCookie(session.SynoToken))
            throw new InvalidOperationException("vm.console.asset_origin");
        using var request = new HttpRequestMessage(HttpMethod.Get, resource);
        request.Headers.Accept.ParseAdd(expectedType);
        request.Headers.Add("Cookie", $"id={session.Sid}");
        if (!string.IsNullOrWhiteSpace(session.SynoToken)) request.Headers.Add("X-SYNO-TOKEN", session.SynoToken);
        SetNasConnectionContext(request, profile);
        using var response = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken).ConfigureAwait(false);
        if (response.StatusCode != HttpStatusCode.OK || response.RequestMessage?.RequestUri != resource)
            throw new DsmException(UserText.Key("VmConsoleLoadFailed"), UserText.Key("VmConsoleReconnect"), (int)response.StatusCode,
                response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden);
        var actualType = response.Content.Headers.ContentType?.MediaType;
        if (!string.Equals(actualType, expectedType, StringComparison.OrdinalIgnoreCase) &&
            !(expectedType == "text/javascript" && string.Equals(actualType, "application/javascript", StringComparison.OrdinalIgnoreCase)) &&
            !(expectedType == "audio/ogg" && string.Equals(actualType, "application/octet-stream", StringComparison.OrdinalIgnoreCase)))
            throw new DsmBinaryResponseException(DsmBinaryResponseFailure.UnexpectedMediaType, "vm.console.asset_type");
        var maximumBytes = expectedType == "application/json" ? VirtualMachineConsolePolicy.MaximumLocaleBytes : MaximumConsoleAssetBytes;
        var data = await ReadBoundedBinaryContentAsync(response.Content, actualType!, maximumBytes, cancellationToken).ConfigureAwait(false);
        return new(data.Bytes, null, response.Content.Headers.ContentType!.ToString());
    }
}
