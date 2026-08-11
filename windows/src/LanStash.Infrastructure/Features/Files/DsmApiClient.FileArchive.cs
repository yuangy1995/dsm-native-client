using System.Buffers;
using System.Net;
using System.Text.Json;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmApiClient
{
    internal const int FolderArchiveChunkSize = 1024 * 1024;

    public async Task StreamFolderArchiveAsync(
        NasProfile profile,
        DsmSession session,
        ApiCapability capability,
        string remotePath,
        Func<ReadOnlyMemory<byte>, CancellationToken, ValueTask> writeChunkAsync,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(remotePath);
        ArgumentNullException.ThrowIfNull(writeChunkAsync);
        if (capability.MinVersion > 2 || capability.MaxVersion < 2)
        {
            throw new FileArchiveContractException(
                FileArchiveContractFailure.UnsupportedVersion,
                "The NAS does not support the verified folder archive version.");
        }

        var path = capability.Path.StartsWith('/')
            ? capability.Path
            : $"/webapi/{capability.Path}";
        var parameters = new Dictionary<string, string>
        {
            ["api"] = capability.Name,
            ["version"] = "2",
            ["method"] = "download",
            ["path"] = JsonSerializer.Serialize(new[] { remotePath }),
            ["mode"] = "download",
            ["_sid"] = session.Sid,
        };
        var query = string.Join(
            "&",
            parameters.Select(pair =>
                $"{Uri.EscapeDataString(pair.Key)}={Uri.EscapeDataString(pair.Value)}"));
        using var request = new HttpRequestMessage(
            HttpMethod.Get,
            new Uri(GetBaseUri(profile), $"{path}?{query}"));
        request.Headers.UserAgent.ParseAdd("LanStash-Windows/0.1");
        if (!string.IsNullOrWhiteSpace(session.SynoToken))
        {
            request.Headers.TryAddWithoutValidation("X-SYNO-TOKEN", session.SynoToken);
        }
        SetNasConnectionContext(request, profile);

        using var response = await _http.SendAsync(
            request,
            HttpCompletionOption.ResponseHeadersRead,
            cancellationToken).ConfigureAwait(false);
        if (response.StatusCode != HttpStatusCode.OK)
        {
            throw new FileArchiveContractException(
                FileArchiveContractFailure.UnexpectedStatus,
                "The NAS did not return a folder archive.",
                (int)response.StatusCode);
        }

        var mediaType = response.Content.Headers.ContentType?.MediaType;
        if (!string.Equals(mediaType, "application/zip", StringComparison.OrdinalIgnoreCase) &&
            !string.Equals(mediaType, "application/octet-stream", StringComparison.OrdinalIgnoreCase))
        {
            throw new FileArchiveContractException(
                FileArchiveContractFailure.UnexpectedMediaType,
                "The NAS returned an unexpected folder archive type.",
                (int)response.StatusCode);
        }
        if (response.Content.Headers.ContentLength == 0)
        {
            throw new FileArchiveContractException(
                FileArchiveContractFailure.EmptyResponse,
                "The NAS returned an empty folder archive.",
                (int)response.StatusCode);
        }

        await using var content = await response.Content.ReadAsStreamAsync(cancellationToken)
            .ConfigureAwait(false);
        var buffer = ArrayPool<byte>.Shared.Rent(FolderArchiveChunkSize);
        try
        {
            var prefixLength = await ReadPrefixAsync(content, buffer, cancellationToken)
                .ConfigureAwait(false);
            if (prefixLength == 0)
            {
                throw new FileArchiveContractException(
                    FileArchiveContractFailure.EmptyResponse,
                    "The NAS returned an empty folder archive.",
                    (int)response.StatusCode);
            }
            if (prefixLength < 4 || !HasZipSignature(buffer))
            {
                throw new FileArchiveContractException(
                    FileArchiveContractFailure.InvalidZipSignature,
                    "The NAS response is not a valid ZIP archive.",
                    (int)response.StatusCode);
            }

            await writeChunkAsync(buffer.AsMemory(0, prefixLength), cancellationToken)
                .ConfigureAwait(false);
            while (true)
            {
                var count = await content.ReadAsync(
                    buffer.AsMemory(0, FolderArchiveChunkSize),
                    cancellationToken).ConfigureAwait(false);
                if (count == 0)
                {
                    break;
                }
                await writeChunkAsync(buffer.AsMemory(0, count), cancellationToken)
                    .ConfigureAwait(false);
            }
        }
        finally
        {
            ArrayPool<byte>.Shared.Return(buffer);
        }
    }

    private static async Task<int> ReadPrefixAsync(
        Stream content,
        byte[] buffer,
        CancellationToken cancellationToken)
    {
        var count = 0;
        while (count < 4)
        {
            var read = await content.ReadAsync(
                buffer.AsMemory(count, 4 - count),
                cancellationToken).ConfigureAwait(false);
            if (read == 0)
            {
                break;
            }
            count += read;
        }
        return count;
    }

    private static bool HasZipSignature(byte[] prefix) =>
        prefix[0] == 0x50 && prefix[1] == 0x4B &&
        ((prefix[2] == 0x03 && prefix[3] == 0x04) ||
         (prefix[2] == 0x05 && prefix[3] == 0x06) ||
         (prefix[2] == 0x07 && prefix[3] == 0x08));
}
