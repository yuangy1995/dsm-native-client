using System.Net;
using System.Net.Http;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmApiClient
{
    private Task<JsonObject> PostAsync(
        NasProfile profile,
        string path,
        IReadOnlyDictionary<string, string> parameters,
        DsmSession? session,
        CancellationToken cancellationToken) =>
        PostAsync(
            profile,
            path,
            parameters,
            session,
            DsmConnectionSource.DirectAddress,
            cancellationToken);

    private async Task<JsonObject> PostAsync(
        NasProfile profile,
        string path,
        IReadOnlyDictionary<string, string> parameters,
        DsmSession? session,
        DsmConnectionSource source,
        CancellationToken cancellationToken)
    {
        var values = new Dictionary<string, string>(parameters, StringComparer.Ordinal);
        if (session is not null)
        {
            values["_sid"] = session.Sid;
        }
        using var request = new HttpRequestMessage(
            HttpMethod.Post,
            new Uri(GetBaseUri(profile), path))
        {
            Content = new FormUrlEncodedContent(values),
        };
        request.Headers.Accept.ParseAdd("application/json");
        request.Headers.UserAgent.ParseAdd("LanStash-Windows/0.1");
        WindowsCertificateTrustHandler.SetConnectionContext(
            request,
            profile.Id,
            source);
        if (session is not null)
        {
            request.Headers.TryAddWithoutValidation("Cookie", $"id={session.Sid}");
            if (!string.IsNullOrWhiteSpace(session.SynoToken))
            {
                request.Headers.TryAddWithoutValidation("X-SYNO-TOKEN", session.SynoToken);
            }
        }

        HttpResponseMessage response;
        try
        {
            response = await _http.SendAsync(
                request,
                HttpCompletionOption.ResponseHeadersRead,
                cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new DsmException(
                UserText.Key("WinShared5a870c4775a4ef6b"),
                UserText.Key("WinShared199c5367bae9682d"));
        }
        catch (HttpRequestException)
        {
            throw new DsmException(
                UserText.Key("WinSharedf91eef8a1cf7b01c"),
                UserText.Key("WinShared79c4d60046afa3ff"));
        }
        using (response)
        {
            if (!response.IsSuccessStatusCode)
            {
                throw new DsmException(
                    UserText.Key("WinSharedf91eef8a1cf7b01c"),
                    UserText.Key("WinShared79c4d60046afa3ff"),
                    (int)response.StatusCode,
                    response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden);
            }
            await using var stream = await response.Content
                .ReadAsStreamAsync(cancellationToken)
                .ConfigureAwait(false);
            var envelope = await JsonNode.ParseAsync(
                stream,
                cancellationToken: cancellationToken).ConfigureAwait(false) as JsonObject
                ?? throw new DsmException(
                    UserText.Key("WinShared9cb9ec075b03b6cb"),
                    UserText.Key("WinShared09f262a53ad074ca"));
            if (envelope["success"]?.GetValue<bool>() == true)
            {
                return envelope["data"] switch
                {
                    JsonObject dataObject => dataObject,
                    JsonArray dataArray => new JsonObject
                    {
                        [DsmApiResponseKeys.RootArray] = dataArray.DeepClone(),
                    },
                    _ => [],
                };
            }
            var code = envelope["error"]?["code"]?.GetValue<int>();
            throw MapFailure(code);
        }
    }

    private static DsmException MapFailure(int? code) => code switch
    {
        102 => new(UserText.Key("WinShared11a208e43c34b77c"), UserText.Key("WinShared371d84f48836296f"), code),
        103 => new(UserText.Key("WinShared189ee06b7da78f3f"), UserText.Key("WinSharedb5641013fbf13d8b"), code),
        104 => new(UserText.Key("WinSharedd727aa9e0a8cff65"), UserText.Key("WinSharedc144a2dc9ace5c1f"), code, true),
        105 => new(UserText.Key("WinShared12188668a1d4cff1"), UserText.Key("WinShared4a1330714c58b25d"), code),
        406 => new(UserText.Key("WinShared3cd43f3a371513e2"), UserText.Key("WinShared46e3e4901826eb40"), code, true),
        407 => new(UserText.Key("WinSharedef0eed96e1f28ed8"), UserText.Key("WinShared2ad42c7573d49cbc"), code, true),
        400 or 401 or 402 or 403 or 404 =>
            new(UserText.Key("WinShared78eee40d2f30576e"), UserText.Key("WinShared2f7ffa8e29481728"), code, true),
        _ => new(UserText.Key("WinShared0addf7c060c570ce"), UserText.Key("WinShared5448ceb91a80e260"), code),
    };
}
