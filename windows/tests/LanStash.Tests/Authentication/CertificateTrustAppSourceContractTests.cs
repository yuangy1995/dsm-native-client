namespace LanStash.Tests.Authentication;

public sealed class CertificateTrustAppSourceContractTests
{
    [Fact]
    public void EveryAttemptLoadsProfilePinAndOwnsOneClientAcrossDiscoveryLoginAndRepository()
    {
        var app = Read("windows/src/LanStash.App/ViewModels/AppViewModel.cs");
        var trust = Read("windows/src/LanStash.App/ViewModels/AppViewModel.CertificateTrust.cs");

        Assert.Contains("CreateCertificateConnectionAsync(\n                input.Profile.Id", app);
        Assert.Contains("CreateCertificateConnectionAsync(\n                profile.Id", app);
        Assert.Contains("_certificatePins.LoadAsync(profileId", trust);
        Assert.Contains("new WindowsCertificateTrustHandler(profileId, pinnedFingerprint)", trust);
        Assert.Contains("Api = new DsmApiClient(_httpClient)", trust);
        Assert.Contains("new DsmQuickConnectResolver(_httpClient)", trust);
        Assert.Contains("connectionContext.Resolver.DiscoverAsync", app);
        Assert.Contains("connectionContext.Api.LoginAsync", app);
        Assert.Contains("connection.Source", app);
        Assert.Contains("new DsmRepository(\n                connection.Profile,\n                session,\n                connectionContext.Api", app);
        Assert.Contains("connectionContext.TakeOwnership()", app);
        Assert.DoesNotContain("private readonly HttpClient _http", app);
    }

    [Fact]
    public void ChallengeUsesAttemptProfileAndPromptGatesAndFrozenInputRetriesOnce()
    {
        var app = Read("windows/src/LanStash.App/ViewModels/AppViewModel.cs");
        var trust = Read("windows/src/LanStash.App/ViewModels/AppViewModel.CertificateTrust.cs");

        Assert.Contains("challenge.ProfileId != input.Profile.Id", trust);
        Assert.Contains("_connectionAttempts.IsCurrent(attempt)", trust);
        Assert.Contains("context.Prompt.Id != promptId", trust);
        Assert.Contains("context.Prompt.ProfileId != context.Prompt.Challenge.ProfileId", trust);
        Assert.Contains("ConnectFrozenAttemptAsync(\n                    context.Connect,\n                    certificateRetry: true)", trust);
        Assert.Contains("if (_connectionAttempts.IsCurrent(attempt) && !certificateRetry)", app);
        Assert.DoesNotContain("ConnectAsync().ConfigureAwait(true)", trust);
        Assert.DoesNotContain("PasswordInput", trust);
    }

    [Fact]
    public void InvalidAndRelayChallengesCannotApproveAndPinIsSavedBeforeRetry()
    {
        var trust = Read("windows/src/LanStash.App/ViewModels/AppViewModel.CertificateTrust.cs");
        var invalid = trust.IndexOf(
            "context.Prompt.Challenge.Kind == CertificateTrustChallengeKind.InvalidCertificate",
            StringComparison.Ordinal);
        var relay = trust.IndexOf(
            "context.Prompt.Challenge.ConnectionSource == DsmConnectionSource.QuickConnectRelay",
            StringComparison.Ordinal);
        var save = trust.IndexOf("_certificatePins.SaveAsync(", StringComparison.Ordinal);
        var retry = trust.IndexOf("ConnectFrozenAttemptAsync(", save, StringComparison.Ordinal);

        Assert.True(invalid >= 0);
        Assert.True(relay > invalid);
        Assert.True(save > relay);
        Assert.True(retry > save);
    }

    [Fact]
    public void CancellationProfileSelectionRemovalAndDisconnectClearTrustState()
    {
        var app = Read("windows/src/LanStash.App/ViewModels/AppViewModel.cs");

        Assert.Contains("public void CancelConnection()", app);
        Assert.Contains("_connectionAttempts.CancelCurrent();\n        ClearCertificateChallenge();", app);
        Assert.Contains("public async Task ConnectAsync()", app);
        Assert.Contains("public async Task RestoreAsync(NasProfile profile", app);
        Assert.True(Count(app, "ClearCertificateChallenge();") >= 4);
        Assert.Contains("public async Task SelectProfileAsync(NasProfile profile)\n    {\n        ClearCertificateChallenge();", app);
        Assert.Contains("await _certificatePins.RemoveAsync(profile.Id)", app);
        Assert.Contains("ActiveConnectionSource = null", app);
        Assert.Contains("_activeHttpClient?.Dispose()", app);
    }

    private static int Count(string value, string pattern) =>
        (value.Length - value.Replace(pattern, string.Empty, StringComparison.Ordinal).Length) /
        pattern.Length;

    private static string Read(string relativePath) =>
        File.ReadAllText(Path.Combine(RepositoryRoot(), relativePath))
            .Replace("\r\n", "\n", StringComparison.Ordinal);

    private static string RepositoryRoot()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null && !Directory.Exists(Path.Combine(directory.FullName, "windows")))
        {
            directory = directory.Parent;
        }
        return directory?.FullName ?? throw new DirectoryNotFoundException("repository root");
    }
}
