using LanStash.App.Features.Files.Preview;
using LanStash.App.Localization;
using LanStash.App.Platform.Office;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using WinRT.Interop;

namespace LanStash.App.Views;

public sealed partial class FilePreviewPane
{
    private WindowsOfficePreviewHost? _officePreview;
#if LANSTASH_UI_SMOKE
    private TextBlock? _officeSyntheticPreview;
#endif
    public void SetOfficeActionsEnabled(bool open, bool edit, bool sessions)
    {
        OfficeOpenCopyButton.IsEnabled = open;
        OfficeAutoEditButton.IsEnabled = edit;
        OfficeSessionsPreviewButton.IsEnabled = sessions;
        OfficeAutoUnavailableText.Visibility = edit ? Visibility.Collapsed : Visibility.Visible;
    }
    public void SuspendOfficePreview(bool suspended) => _officePreview?.Suspend(suspended);
    internal void SetOfficeSessionStatus(string? status)
    { OfficeSessionStatusText.Text = status ?? string.Empty; OfficeSessionStatusButton.Visibility = string.IsNullOrEmpty(status) ? Visibility.Collapsed : Visibility.Visible; }

    private void PresentOffice(FilePreviewSnapshot snapshot)
    {
        OfficePreviewPanel.Visibility = Visibility.Visible;
        var result = OfficePreviewResult.Failed;
#if LANSTASH_UI_SMOKE
        if (Environment.GetEnvironmentVariable("LANSTASH_SMOKE_SCENARIO") == "office")
        {
            result = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") == "preview-failed" ? OfficePreviewResult.Failed : OfficePreviewResult.NotInstalled;
            if (Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") == "preview-ready")
            {
                result = OfficePreviewResult.Ready;
                _officeSyntheticPreview = new TextBlock { Text = "Synthetic document\n\nSample content for native layout review.",
                    TextWrapping = TextWrapping.Wrap, Margin = new(20), FontSize = 20 };
                OfficePreviewSurface.Children.Add(_officeSyntheticPreview);
            }
        }
        else
#endif
        if (snapshot.Artifact is { } artifact && (Application.Current as App)?.MainWindow is { } window)
        {
            _officePreview = new(OfficePreviewSurface,
                () => OfficeOpenCopyButton.Focus(FocusState.Programmatic),
                () => CloseRequested?.Invoke(this, EventArgs.Empty));
            result = _officePreview.Show(artifact.Path, WindowNative.GetWindowHandle(window), LocalizationService.Current.Get("OfficePreviewAccessible"));
        }
        OfficePreviewFallback.Visibility = result == OfficePreviewResult.Ready ? Visibility.Collapsed : Visibility.Visible;
        OfficeFocusPreviewButton.Visibility = result == OfficePreviewResult.Ready ? Visibility.Visible : Visibility.Collapsed;
        OfficePreviewFallbackTitle.Text = LocalizationService.Current.Get(result == OfficePreviewResult.NotInstalled ? "OfficePreviewMissingTitle" : "OfficePreviewFailedTitle");
        OfficePreviewFallbackMessage.Text = LocalizationService.Current.Get(result == OfficePreviewResult.NotInstalled ? "OfficePreviewMissingMessage" : "OfficePreviewFailedMessage");
    }

    private void ReleaseOfficePreview()
    {
        _officePreview?.Dispose(); _officePreview = null; OfficePreviewPanel.Visibility = Visibility.Collapsed;
#if LANSTASH_UI_SMOKE
        if (_officeSyntheticPreview is not null) { OfficePreviewSurface.Children.Remove(_officeSyntheticPreview); _officeSyntheticPreview = null; }
#endif
    }
    private void OfficeFocusPreview_Click(object sender, RoutedEventArgs args) => _officePreview?.Focus();
    private void OfficeSessions_Click(object sender, RoutedEventArgs args) => OfficeSessionsRequested?.Invoke(this, EventArgs.Empty);
    private void OfficeOpenCopy_Click(SplitButton sender, SplitButtonClickEventArgs args) => RequestOfficeAction(false, false);
    private void OfficeOpenWith_Click(object sender, RoutedEventArgs args) => AfterOfficeFlyout(OfficeOpenCopyButton.Flyout, false);
    private void OfficeAutoEdit_Click(SplitButton sender, SplitButtonClickEventArgs args) => RequestOfficeAction(true, false);
    private void OfficeEditWith_Click(object sender, RoutedEventArgs args) => AfterOfficeFlyout(OfficeAutoEditButton.Flyout, true);
    private void AfterOfficeFlyout(Microsoft.UI.Xaml.Controls.Primitives.FlyoutBase flyout, bool autoSave)
    {
        void Closed(object? sender, object args)
        { flyout.Closed -= Closed; if (!_disposed) RequestOfficeAction(autoSave, true); }
        flyout.Closed += Closed; flyout.Hide();
    }
    private void RequestOfficeAction(bool autoSave, bool chooseApplication)
    {
        if (_viewModel?.Snapshot is not { Kind: FilePreviewKind.Office, ProfileId: { } profileId, Item: { } item } ||
            autoSave && !OfficeAutoEditButton.IsEnabled || !autoSave && !OfficeOpenCopyButton.IsEnabled) return;
        OfficeActionRequested?.Invoke(this, new(new(profileId, item), autoSave, chooseApplication));
    }
}

public sealed class OfficePreviewActionEventArgs(FilePreviewSaveCopyTarget target, bool autoSave, bool chooseApplication) : EventArgs
{
    public FilePreviewSaveCopyTarget Target { get; } = target;
    public bool AutoSave { get; } = autoSave;
    public bool ChooseApplication { get; } = chooseApplication;
}
