using System.Net;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Authentication;

public sealed class CertificateConnectionContextTests
{
    [Fact]
    public async Task FixedReadPublishesProfileAndDirectSourceToTrustHandler()
    {
        var handler = new ContextCapturingHandler();
        var client = new DsmApiClient(new HttpClient(handler));
        var profile = new NasProfile(Guid.NewGuid(), "Synthetic NAS",
            "nas.example.invalid", null, "synthetic-user");
        var session = new DsmSession(profile.Id, "synthetic-session", null, null);
        var capability = new ApiCapability(
            "SYNO.FileStation.List", "entry.cgi", 2, 2, "FORM");

        _ = await client.CallReadJsonObjectAsync(profile, session, capability, 2,
            "list", new Dictionary<string, string>
            {
                ["folder_path"] = "/synthetic",
                ["offset"] = "0",
                ["limit"] = "1",
            });

        Assert.Equal(profile.Id, handler.ProfileId);
        Assert.Equal(DsmConnectionSource.DirectAddress, handler.Source);
    }

    [Fact]
    public void EveryRawNasSendHasAContextAssignmentAndQuickConnectControlPlaneHasNone()
    {
        var api = Read("windows/src/LanStash.Infrastructure/DsmApiClient.cs");
        var quickConnect = Read("windows/src/LanStash.Infrastructure/DsmQuickConnectResolver.cs");

        Assert.Equal(9, Count(api, "_http.SendAsync("));
        Assert.Equal(7, Count(api, "SetNasConnectionContext(request, profile);"));
        Assert.Equal(2, Count(api, "WindowsCertificateTrustHandler.SetConnectionContext("));
        Assert.DoesNotContain("SetConnectionContext", quickConnect, StringComparison.Ordinal);
        foreach (var credential in new[] { "_sid", "SynoToken", "Cookie", "passwd" })
            Assert.DoesNotContain(credential, quickConnect, StringComparison.OrdinalIgnoreCase);
    }

    private static int Count(string value, string pattern) =>
        (value.Length - value.Replace(pattern, string.Empty, StringComparison.Ordinal).Length) /
        pattern.Length;

    private static string Read(string relativePath) =>
        File.ReadAllText(Path.Combine(RepositoryRoot(), relativePath));

    private static string RepositoryRoot()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null && !Directory.Exists(Path.Combine(directory.FullName, "windows")))
            directory = directory.Parent;
        return directory?.FullName ?? throw new DirectoryNotFoundException("repository root");
    }

    private sealed class ContextCapturingHandler : HttpMessageHandler
    {
        public Guid? ProfileId { get; private set; }
        public DsmConnectionSource? Source { get; private set; }

        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            if (WindowsCertificateTrustHandler.TryGetConnectionContext(
                    request, out var profileId, out var source))
            {
                ProfileId = profileId;
                Source = source;
            }
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent("""{"success":true,"data":{}}"""),
            });
        }
    }
}
