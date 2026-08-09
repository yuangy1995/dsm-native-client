using LanStash.App.Localization;
using LanStash.App.Features.Authentication;
using LanStash.App.ViewModels;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class LoginPage : Page
{
    private readonly AppViewModel _viewModel;
    private bool _isLoadingLanguage;
    private bool _isSubscribed;
    private Guid? _shownCertificatePromptId;
    private bool _confirmedCertificatePrompt;

    public LoginPage(AppViewModel viewModel)
    {
        InitializeComponent();
        _viewModel = viewModel;
        DataContext = viewModel;
        LoadLanguageOptions();
        UpdateState();
    }

    private void LoginPage_Loaded(object sender, RoutedEventArgs e)
    {
        if (!_isSubscribed)
        {
            _viewModel.PropertyChanged += ViewModel_PropertyChanged;
            _viewModel.PasswordLoaded += ViewModel_PasswordLoaded;
            _isSubscribed = true;
        }
        DispatcherQueue.TryEnqueue(ShowCertificateTrustIfNeeded);
    }

    private void ViewModel_PasswordLoaded(object? sender, string password) =>
        DispatcherQueue.TryEnqueue(() => PasswordInput.Password = password);

    private void ViewModel_PropertyChanged(
        object? sender,
        System.ComponentModel.PropertyChangedEventArgs e)
    {
        UpdateState();
        if (e.PropertyName == nameof(AppViewModel.CertificateTrust))
        {
            DispatcherQueue.TryEnqueue(ShowCertificateTrustIfNeeded);
        }
    }

    private void LoadLanguageOptions()
    {
        _isLoadingLanguage = true;
        var localization = LocalizationService.Current;
        LanguageLabel.Text = localization.Get("LanguageTitle");
        LanguageNote.Text = localization.Get("LanguageFallbackNote");
        LanguageSelector.ItemsSource = localization.Choices();
        LanguageSelector.SelectedItem = localization.Choices()
            .First(choice => choice.Value == localization.Selection);
        _isLoadingLanguage = false;
    }

    private void LanguageSelector_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_isLoadingLanguage || LanguageSelector.SelectedItem is not LanguageChoice choice)
        {
            return;
        }
        LocalizationService.Current.SetSelection(choice.Value);
    }

    private async void ProfileList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (ProfileList.SelectedItem is not NasProfile profile || _viewModel.IsBusy)
        {
            return;
        }
        await _viewModel.SelectProfileAsync(profile);
        PasswordInput.Password = _viewModel.Password;
        await _viewModel.RestoreAsync(profile);
    }

    private void NewProfile_Click(object sender, RoutedEventArgs e)
    {
        ProfileList.SelectedItem = null;
        PasswordInput.Password = string.Empty;
        OtpInput.Password = string.Empty;
        _viewModel.NewProfile();
    }

    private async void Connect_Click(object sender, RoutedEventArgs e)
    {
        _viewModel.Password = PasswordInput.Password;
        _viewModel.Otp = OtpInput.Password;
        await _viewModel.ConnectAsync();
    }

    private void CancelConnect_Click(object sender, RoutedEventArgs e) =>
        _viewModel.CancelConnection();

    private async void ShowCertificateTrustIfNeeded()
    {
        var presentation = _viewModel.CertificateTrust;
        if (presentation is null)
        {
            if (_shownCertificatePromptId is not null)
            {
                _confirmedCertificatePrompt = true;
                CertificateTrustDialog.Hide();
            }
            return;
        }
        if (presentation.Id == _shownCertificatePromptId ||
            XamlRoot is null)
        {
            return;
        }
        _shownCertificatePromptId = presentation.Id;
        _confirmedCertificatePrompt = false;
        ConfigureCertificateDialog(presentation);
        CertificateTrustDialog.XamlRoot = XamlRoot;
        try
        {
            await CertificateTrustDialog.ShowAsync();
        }
        catch (InvalidOperationException) when (XamlRoot is null)
        {
            _viewModel.CancelCertificateTrust(presentation.Id);
        }
        finally
        {
            if (_shownCertificatePromptId == presentation.Id)
            {
                _shownCertificatePromptId = null;
            }
        }
    }

    private void ConfigureCertificateDialog(CertificateTrustPresentation presentation)
    {
        var localization = LocalizationService.Current;
        var challenge = presentation.Challenge;
        var changed = challenge.Kind == CertificateTrustChallengeKind.CertificateChanged;
        var canApprove = challenge.CanApprove &&
            challenge.Kind != CertificateTrustChallengeKind.InvalidCertificate &&
            challenge.ConnectionSource != DsmConnectionSource.QuickConnectRelay;
        CertificateTrustDialog.Title = localization.Get(changed
            ? "CertificateTrustChangedTitle"
            : challenge.Kind == CertificateTrustChallengeKind.FirstUntrustedCertificate
                ? "CertificateTrustFirstTitle"
                : "CertificateTrustInvalidTitle");
        CertificateWarningBar.Title = localization.Get(changed
            ? "CertificateTrustChangedWarningTitle"
            : "CertificateTrustWarningTitle");
        CertificateWarningBar.Message = localization.Get(changed
            ? "CertificateTrustChangedWarningMessage"
            : "CertificateTrustWarningMessage");
        CertificateExplanation.Text = string.Format(
            localization.Get(canApprove
                ? "CertificateTrustReviewExplanation"
                : "CertificateTrustCannotApproveExplanation"),
            CertificateSubjectForDisplay(challenge.SubjectSummary, localization));
        CertificateNasLabel.Text = localization.Get("CertificateTrustNasLabel");
        CertificateNasValue.Text = presentation.ProfileDisplayName;
        CertificateAddressLabel.Text = localization.Get("CertificateTrustAddressLabel");
        CertificateAddressValue.Text = presentation.SubmittedHost;
        CertificateConnectionLabel.Text = localization.Get("CertificateTrustConnectionLabel");
        CertificateConnectionValue.Text = localization.Get(ConnectionSourceKey(challenge.ConnectionSource));
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(
            CertificateNasValue,
            CertificateNasLabel.Text);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(
            CertificateAddressValue,
            CertificateAddressLabel.Text);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(
            CertificateConnectionValue,
            CertificateConnectionLabel.Text);
        PreviousFingerprintPanel.Visibility = changed ? Visibility.Visible : Visibility.Collapsed;
        PreviousFingerprintLabel.Text = localization.Get("CertificateTrustPreviousFingerprintLabel");
        PreviousFingerprintValue.Text = challenge.PreviouslyPinnedFingerprint?.Formatted ?? string.Empty;
        PresentedFingerprintLabel.Text = localization.Get("CertificateTrustPresentedFingerprintLabel");
        PresentedFingerprintValue.Text = challenge.PresentedFingerprint.Formatted;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(
            PreviousFingerprintValue,
            localization.Get("CertificateTrustPreviousFingerprintAutomationName"));
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(
            PresentedFingerprintValue,
            localization.Get("CertificateTrustPresentedFingerprintAutomationName"));
        CertificateNextStep.Text = localization.Get(canApprove
            ? "CertificateTrustApproveNextStep"
            : "CertificateTrustBlockedNextStep");
        CertificateTrustDialog.PrimaryButtonText = canApprove
            ? localization.Get(changed
                ? "CertificateTrustApproveChangedAction"
                : "CertificateTrustApproveAction")
            : string.Empty;
        CertificateTrustDialog.CloseButtonText = localization.Get("ActionCancel");
        CertificateTrustDialog.IsPrimaryButtonEnabled = canApprove;
        CertificateTrustDialog.DefaultButton = ContentDialogButton.Close;
    }

    private async void CertificateTrustDialog_PrimaryButtonClick(
        ContentDialog sender,
        ContentDialogButtonClickEventArgs args)
    {
        var promptId = _shownCertificatePromptId;
        if (promptId is null)
        {
            args.Cancel = true;
            return;
        }
        var deferral = args.GetDeferral();
        sender.IsPrimaryButtonEnabled = false;
        try
        {
            _confirmedCertificatePrompt = await _viewModel
                .ConfirmCertificateTrustAsync(promptId.Value);
        }
        finally
        {
            deferral.Complete();
        }
    }

    private void CertificateTrustDialog_Closing(
        ContentDialog sender,
        ContentDialogClosingEventArgs args)
    {
        if (!_confirmedCertificatePrompt && _shownCertificatePromptId is { } promptId)
        {
            _viewModel.CancelCertificateTrust(promptId);
        }
    }

    private void LoginPage_Unloaded(object sender, RoutedEventArgs e)
    {
        if (_isSubscribed)
        {
            _viewModel.PropertyChanged -= ViewModel_PropertyChanged;
            _viewModel.PasswordLoaded -= ViewModel_PasswordLoaded;
            _isSubscribed = false;
        }
        var promptId = _shownCertificatePromptId ?? _viewModel.CertificateTrust?.Id;
        if (promptId is not null)
        {
            _viewModel.CancelCertificateTrust(promptId.Value);
        }
        if (_shownCertificatePromptId is not null)
        {
            CertificateTrustDialog.Hide();
        }
    }

    private static string ConnectionSourceKey(DsmConnectionSource source) => source switch
    {
        DsmConnectionSource.DirectAddress => "CertificateTrustConnectionDirect",
        DsmConnectionSource.QuickConnectLan => "CertificateTrustConnectionLan",
        DsmConnectionSource.QuickConnectExternal => "CertificateTrustConnectionExternal",
        DsmConnectionSource.QuickConnectRelay => "CertificateTrustConnectionRelay",
        _ => "CertificateTrustConnectionDirect",
    };

    private static string CertificateSubjectForDisplay(
        string subjectSummary,
        LocalizationService localization) =>
        string.Equals(
            subjectSummary,
            "certificate.subject.unavailable",
            StringComparison.Ordinal)
            ? localization.Get("CertificateTrustSubjectUnavailable")
            : subjectSummary;

    private void UpdateState()
    {
        if (ConnectButton is null)
        {
            return;
        }
        ConnectButton.IsEnabled = !_viewModel.IsBusy;
        AddNasButton.IsEnabled = !_viewModel.IsBusy;
        ProfileList.IsEnabled = !_viewModel.IsBusy;
        SetControlsEnabled(ConnectionFields, !_viewModel.IsBusy);
        CancelConnectButton.Visibility = _viewModel.IsBusy
            ? Visibility.Visible
            : Visibility.Collapsed;
        BusyIndicator.IsActive = _viewModel.IsBusy;
        ErrorBar.IsOpen = !string.IsNullOrWhiteSpace(_viewModel.ErrorMessage);
        StatusBar.IsOpen = !string.IsNullOrWhiteSpace(_viewModel.ConnectionStatus);
    }

    private static void SetControlsEnabled(DependencyObject root, bool isEnabled)
    {
        var childCount = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChildrenCount(root);
        for (var index = 0; index < childCount; index++)
        {
            var child = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChild(root, index);
            if (child is Control control)
            {
                control.IsEnabled = isEnabled;
            }
            SetControlsEnabled(child, isEnabled);
        }
    }
}
