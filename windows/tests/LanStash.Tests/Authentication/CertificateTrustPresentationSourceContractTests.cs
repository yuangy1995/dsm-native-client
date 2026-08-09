using System.Xml.Linq;

namespace LanStash.Tests.Authentication;

public sealed class CertificateTrustPresentationSourceContractTests
{
    [Fact]
    public void LoginUsesNativeScrollableDialogWithFingerprintAndAccessibleTargets()
    {
        var xaml = Read("windows/src/LanStash.App/Views/LoginPage.xaml");
        _ = XDocument.Parse(xaml);

        Assert.Contains("<ContentDialog", xaml);
        Assert.Contains("DefaultButton=\"Close\"", xaml);
        Assert.Contains("PrimaryButtonClick=\"CertificateTrustDialog_PrimaryButtonClick\"", xaml);
        Assert.Contains("Closing=\"CertificateTrustDialog_Closing\"", xaml);
        Assert.Contains("<ScrollViewer MaxHeight=\"560\"", xaml);
        Assert.Contains("AutomationProperties.LiveSetting=\"Polite\"", xaml);
        Assert.Contains("x:Name=\"PreviousFingerprintValue\"", xaml);
        Assert.Contains("x:Name=\"PresentedFingerprintValue\"", xaml);
        Assert.Equal(2, Count(xaml, "MinHeight=\"48\""));
        Assert.DoesNotContain("Foreground=\"#", xaml);
        Assert.DoesNotContain("Background=\"#", xaml);
    }

    [Fact]
    public void DialogNeverOffersApprovalForInvalidOrRelayAndLeavingCancelsPrompt()
    {
        var source = Read("windows/src/LanStash.App/Views/LoginPage.xaml.cs");

        Assert.Contains("challenge.Kind != CertificateTrustChallengeKind.InvalidCertificate", source);
        Assert.Contains("challenge.ConnectionSource != DsmConnectionSource.QuickConnectRelay", source);
        Assert.Contains("CertificateTrustDialog.PrimaryButtonText = canApprove", source);
        Assert.Contains("CertificateTrustDialog.DefaultButton = ContentDialogButton.Close", source);
        Assert.Contains("CertificateTrustDialog_Closing", source);
        Assert.Contains("LoginPage_Unloaded", source);
        Assert.Contains("LoginPage_Loaded", source);
        Assert.Contains("_viewModel.PropertyChanged -= ViewModel_PropertyChanged", source);
        Assert.Contains("_viewModel.PasswordLoaded -= ViewModel_PasswordLoaded", source);
        Assert.Contains("_shownCertificatePromptId ?? _viewModel.CertificateTrust?.Id", source);
        Assert.Contains("_viewModel.CancelCertificateTrust(promptId.Value)", source);
        Assert.Contains("CertificateTrustDialog.Hide()", source);
    }

    [Fact]
    public void VisibleTextUsesLocalizationAndNarratorNamesBothFingerprints()
    {
        var source = Read("windows/src/LanStash.App/Views/LoginPage.xaml.cs");

        foreach (var key in new[]
        {
            "CertificateTrustChangedTitle",
            "CertificateTrustFirstTitle",
            "CertificateTrustInvalidTitle",
            "CertificateTrustReviewExplanation",
            "CertificateTrustCannotApproveExplanation",
            "CertificateTrustPreviousFingerprintAutomationName",
            "CertificateTrustPresentedFingerprintAutomationName",
            "CertificateTrustApproveChangedAction",
            "CertificateTrustApproveAction",
            "CertificateTrustBlockedNextStep",
        })
        {
            Assert.Contains($"\"{key}\"", source);
        }
        Assert.Contains("AutomationProperties.SetName", source);
        Assert.Contains("CertificateNasValue,\n            CertificateNasLabel.Text", source);
        Assert.Contains("CertificateAddressValue,\n            CertificateAddressLabel.Text", source);
        Assert.Contains("CertificateConnectionValue,\n            CertificateConnectionLabel.Text", source);
    }

    [Fact]
    public void UnavailableSubjectTagIsLocalizedOnlyAtPresentationBoundary()
    {
        var source = Read("windows/src/LanStash.App/Views/LoginPage.xaml.cs");

        Assert.Contains("CertificateSubjectForDisplay(challenge.SubjectSummary, localization)", source);
        Assert.Contains("\"certificate.subject.unavailable\"", source);
        Assert.Contains("StringComparison.Ordinal", source);
        Assert.Contains("localization.Get(\"CertificateTrustSubjectUnavailable\")", source);
        Assert.Contains(": subjectSummary;", source);
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
