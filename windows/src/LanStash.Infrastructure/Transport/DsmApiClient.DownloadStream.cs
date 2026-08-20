using System.Buffers;
using System.Net;
using System.Net.Http;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmApiClient
{
    public async Task<DsmBinaryResponse> ReadBinaryAsync(
        NasProfile profile,
        DsmSession session,
        ApiCapability capability,
        string method,
        IReadOnlyDictionary<string, string>? parameters,
        string acceptedMediaTypePrefix,
        int maximumBytes,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(method);
        ArgumentException.ThrowIfNullOrWhiteSpace(acceptedMediaTypePrefix);
        ArgumentOutOfRangeException.ThrowIfLessThan(maximumBytes, 1);
        if (parameters?.Keys.Any(IsAuthenticationParameter) == true)
        {
            throw new ArgumentException(
                "Authentication material must be supplied through the session, not binary request parameters.",
                nameof(parameters));
        }

        var values = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["api"] = capability.Name,
            ["version"] = capability.SelectVersion(2).ToString(
                System.Globalization.CultureInfo.InvariantCulture),
            ["method"] = method,
        };
        if (parameters is not null)
        {
            foreach (var (key, value) in parameters)
            {
                values[key] = value;
            }
        }
        var query = string.Join(
            "&",
            values.Select(pair =>
                $"{Uri.EscapeDataString(pair.Key)}={Uri.EscapeDataString(pair.Value)}"));
        if (string.IsNullOrWhiteSpace(capability.Path) ||
            capability.Path.StartsWith("//", StringComparison.Ordinal) ||
            capability.Path.StartsWith('\\') ||
            capability.Path.Contains('?') ||
            capability.Path.Contains('#'))
        {
            throw new ArgumentException(
                "The binary API capability path is invalid.",
                nameof(capability));
        }
        var path = capability.Path.StartsWith('/')
            ? capability.Path
            : $"/webapi/{capability.Path}";
        var baseUri = GetBaseUri(profile);
        var requestUri = new Uri(baseUri, $"{path}?{query}");
        if (!string.Equals(requestUri.Scheme, baseUri.Scheme, StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(requestUri.Host, baseUri.Host, StringComparison.OrdinalIgnoreCase) ||
            requestUri.Port != baseUri.Port)
        {
            throw new ArgumentException(
                "The binary API capability path changes the NAS authority.",
                nameof(capability));
        }
        using var request = new HttpRequestMessage(
            HttpMethod.Get,
            requestUri);
        request.Headers.Accept.ParseAdd($"{acceptedMediaTypePrefix}*");
        request.Headers.UserAgent.ParseAdd("LanStash-Windows/0.1");
        request.Headers.TryAddWithoutValidation("Cookie", $"id={session.Sid}");
        if (!string.IsNullOrWhiteSpace(session.SynoToken))
        {
            request.Headers.TryAddWithoutValidation("X-SYNO-TOKEN", session.SynoToken);
        }

        SetNasConnectionContext(request, profile);
        using var response = await _http.SendAsync(
            request,
            HttpCompletionOption.ResponseHeadersRead,
            cancellationToken).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode)
        {
            throw new DsmException(
                UserText.Key("WinSharedf91eef8a1cf7b01c"),
                UserText.Key("WinShared79c4d60046afa3ff"),
                (int)response.StatusCode,
                response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden);
        }

        var mediaType = response.Content.Headers.ContentType?.MediaType ?? string.Empty;
        if (!mediaType.StartsWith(acceptedMediaTypePrefix, StringComparison.OrdinalIgnoreCase))
        {
            throw new DsmBinaryResponseException(
                DsmBinaryResponseFailure.UnexpectedMediaType,
                "The binary response media type does not match the requested contract.");
        }
        if (response.Content.Headers.ContentLength is { } contentLength &&
            contentLength > maximumBytes)
        {
            throw new DsmBinaryResponseException(
                DsmBinaryResponseFailure.ResponseTooLarge,
                "The binary response exceeds the configured byte limit.");
        }

        await using var source = await response.Content
            .ReadAsStreamAsync(cancellationToken)
            .ConfigureAwait(false);
        using var destination = new MemoryStream(
            Math.Min(maximumBytes, 64 * 1024));
        var buffer = ArrayPool<byte>.Shared.Rent(64 * 1024);
        try
        {
            var total = 0;
            while (true)
            {
                var requested = total < maximumBytes
                    ? Math.Min(buffer.Length, maximumBytes - total)
                    : 1;
                var read = await source.ReadAsync(
                    buffer.AsMemory(0, requested),
                    cancellationToken).ConfigureAwait(false);
                if (read == 0)
                {
                    break;
                }
                total += read;
                if (total > maximumBytes)
                {
                    throw new DsmBinaryResponseException(
                        DsmBinaryResponseFailure.ResponseTooLarge,
                        "The binary response exceeds the configured byte limit.");
                }
                await destination.WriteAsync(
                    buffer.AsMemory(0, read),
                    cancellationToken).ConfigureAwait(false);
            }
        }
        finally
        {
            ArrayPool<byte>.Shared.Return(buffer);
        }

        if (destination.Length == 0)
        {
            throw new DsmBinaryResponseException(
                DsmBinaryResponseFailure.EmptyBody,
                "The binary response is empty.");
        }
        return new DsmBinaryResponse(destination.ToArray(), mediaType);
    }

    private static bool IsAuthenticationParameter(string name) =>
        name.Equals("_sid", StringComparison.OrdinalIgnoreCase) ||
        name.Equals("sid", StringComparison.OrdinalIgnoreCase) ||
        name.Equals("synotoken", StringComparison.OrdinalIgnoreCase);
}
