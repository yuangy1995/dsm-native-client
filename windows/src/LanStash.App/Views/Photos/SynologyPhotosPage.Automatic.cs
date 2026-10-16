using System.ComponentModel;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;

namespace LanStash.App.Views.Photos;

public sealed partial class SynologyPhotosPage
{
    private DispatcherTimer? _automaticTimer;
    private void StartAutomaticPreviews()
    {
        if (_disposed || !_windowVisible || !_model.Repository.SupportsManagement) return;
        _model.Automatic.SetActive(true);
        if (_automaticTimer is null)
        {
            _automaticTimer = new() { Interval = TimeSpan.FromMilliseconds(250) };
            _automaticTimer.Tick += async (_, _) => await TickAutomaticPreviewsAsync();
        }
        _automaticTimer.Start(); _ = TickAutomaticPreviewsAsync();
    }
    private async Task TickAutomaticPreviewsAsync()
    {
        if (_disposed || !_windowVisible || !IsLoaded) return;
        var now = DateTimeOffset.UtcNow; _model.Automatic.SetVisible(VisibleAutomaticPhotos(), now);
        var busy = _dialog is not null && !_model.Automatic.SettingsVisible || MoreButton.Flyout.IsOpen || _managementPreparing ||
            _previewPreparing || _previewRuns.Count > 0 || _uploadPreparing || _exportStarting || _isSaving || _model.Preview.IsLoading || _imageDecodePending;
        _model.Automatic.SetInteractionBusy(busy);
        await _model.Automatic.TickAsync(_model.AutomaticContext(busy), now);
    }
    private IEnumerable<SynologyPhotoIdentity> VisibleAutomaticPhotos()
    {
        if (PreviewRoot.Visibility == Visibility.Visible || LibraryGrid.Visibility != Visibility.Visible ||
            FindChild<ScrollViewer>(LibraryGrid) is not { } scroll || scroll.ActualWidth <= 0 || scroll.ActualHeight <= 0) yield break;
        var viewport = new Rect(0, 0, scroll.ActualWidth, scroll.ActualHeight);
        // 实际裁剪后的面积决定可见性，不能将已实现但滚出窗口的容器算作可见项。
        foreach (var item in RealizedPhotoItems(LibraryGrid))
        {
            if (item.Content is not SynologyPhotoCell { Photo: { } photo } || item.ActualWidth <= 0 || item.ActualHeight <= 0) continue;
            var bounds = item.TransformToVisual(scroll).TransformBounds(new(0, 0, item.ActualWidth, item.ActualHeight));
            var width = Math.Max(0, Math.Min(bounds.Right, viewport.Right) - Math.Max(bounds.Left, viewport.Left));
            var height = Math.Max(0, Math.Min(bounds.Bottom, viewport.Bottom) - Math.Max(bounds.Top, viewport.Top));
            if (width * height >= bounds.Width * bounds.Height * 0.8) yield return photo.Id;
        }
    }
    private static IEnumerable<GridViewItem> RealizedPhotoItems(DependencyObject root)
    {
        for (var index = 0; index < VisualTreeHelper.GetChildrenCount(root); index++)
        {
            var child = VisualTreeHelper.GetChild(root, index);
            if (child is GridViewItem item) yield return item;
            else foreach (var descendant in RealizedPhotoItems(child)) yield return descendant;
        }
    }
    private void AutomaticChanged(object? sender, PropertyChangedEventArgs args) => RenderAutomaticPreviews();
    private void AutomaticPreviewChanged()
    { if (!_disposed) { CancelThumbnails(); _thumbnails.Clear(); RebuildGroups(); } }
    private string AutomaticStatus()
    {
        var state = _model.Automatic;
        return state.PendingSetting is not null ? _l.Get("PhotosAutomaticSaving") : state.Filename is { } filename ? _l.Format("PhotosAutomaticGenerating", filename) :
            state.HasPending ? _l.Get("PhotosAutomaticFinishing") : state.ErrorKey is { } error ? _l.Get(error) : _l.Get("PhotosAutomaticPaused");
    }
    private void RenderAutomaticPreviews()
    {
        if (!_ready || _disposed) return;
        RenderPhotoPreferenceControls();
        var state = _model.Automatic; AutomaticPhotoPreviewsMenu.Text = _l.Get("PhotosAutomaticPreviews");
        AutomaticPhotoPreviewsMenu.Visibility = Visible(_model.Repository.SupportsManagement && _model.Spaces.Any(_model.Repository.SupportsAutomaticPreview));
        var message = AutomaticStatus(); var preview = PreviewRoot.Visibility == Visibility.Visible;
        foreach (var bar in new[] { AutomaticPreviewBar, PreviewAutomaticBar })
        {
            // 只更新当前页面的可见状态，空闲轮询不能反复驱动被预览遮住的图库布局。
            var show = state.ShowsStatus && (ReferenceEquals(bar, PreviewAutomaticBar) == preview);
            if (bar.Message != message) bar.Message = message;
            var severity = state.ErrorKey is not null && !state.HasPending ? InfoBarSeverity.Warning : InfoBarSeverity.Informational;
            if (bar.Severity != severity) bar.Severity = severity;
            if (bar.IsOpen != show) bar.IsOpen = show;
        }
        foreach (var button in new[] { AutomaticPreviewAction, PreviewAutomaticAction })
        {
            var caption = _l.Get(state.HasPending || state.PendingSetting is not null ? "PhotosAutomaticPreviews" : state.Paused || state.ErrorKey is not null ? "PhotosAutomaticResume" : "PhotosAutomaticPause");
            if (!Equals(button.Content, caption)) button.Content = caption;
            if (button.IsEnabled == state.IsSaving) button.IsEnabled = !state.IsSaving;
        }
    }
    private async void AutomaticPhotoPreviews_Click(object sender, RoutedEventArgs args) => await ShowAutomaticPreviewsAsync();
    private async void AutomaticPreviewAction_Click(object sender, RoutedEventArgs args)
    {
        var state = _model.Automatic;
        if (state.HasPending || state.PendingSetting is not null) await ShowAutomaticPreviewsAsync();
        else if (state.Paused || state.ErrorKey is not null) state.Resume(); else state.Pause();
    }
    private async Task ShowAutomaticPreviewsAsync()
    {
        if (_disposed || _dialog is not null || _model.Automatic.SettingsVisible) return;
        var generation = _viewGeneration; var state = _model.Automatic; state.SettingsVisible = true; await state.YieldAsync();
        if (_disposed || generation != _viewGeneration) { state.SettingsVisible = false; return; }
        var closed = false; var rendered = false;
        var toggle = new ToggleSwitch { Header = _l.Get("PhotosAutomaticEnable"), IsEnabled = false,
            OnContent = _l.Get("PhotosAutomaticOn"), OffContent = _l.Get("PhotosAutomaticOff") };
        AutomationProperties.SetAutomationId(toggle, "PhotosAutomaticToggle"); AutomationProperties.SetName(toggle, _l.Get("PhotosAutomaticEnable"));
        var message = new TextBlock { Text = _l.Get("PhotosLoadingDescription"), TextWrapping = TextWrapping.Wrap };
        var support = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var pause = new Button { Content = _l.Get("PhotosAutomaticPause") };
        var retry = new Button { Content = _l.Get("PhotosRetry") };
        var panel = new StackPanel { MinWidth = 280, MaxWidth = 560, Spacing = 12 };
        foreach (var element in new FrameworkElement[] { toggle, support, message, pause, retry }) panel.Children.Add(element);
        var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = _l.Get("PhotosAutomaticPreviews"),
            PrimaryButtonText = _l.Get("PhotosSaveChanges"), IsPrimaryButtonEnabled = false, CloseButtonText = _l.Get("PhotosClose"), Content = panel };
        bool Current() => !closed && !_disposed && generation == _viewGeneration;
        void RenderSetting()
        {
            if (!Current()) return;
            if (!rendered && state.Enabled is { } enabled) { toggle.IsOn = enabled; rendered = true; }
            toggle.IsEnabled = state.CanChangeSetting; dialog.IsPrimaryButtonEnabled = state.CanChangeSetting && state.Enabled != toggle.IsOn;
            message.Text = state.ShowsStatus ? AutomaticStatus() : state.Enabled is null ? _l.Get(state.ErrorKey ?? "PhotosLoadingDescription") : "";
            message.Visibility = Visible(message.Text.Length > 0);
            support.Text = _l.Get("PhotosAutomaticUnsupported"); support.Visibility = Visible(state.Enabled is not null && !state.Support.Available);
            pause.Visibility = Visible(state.Enabled == true); pause.IsEnabled = !state.IsSaving;
            pause.Content = _l.Get(state.Paused || state.ErrorKey is not null ? "PhotosAutomaticResume" : "PhotosAutomaticPause");
            retry.Visibility = Visible(state.Enabled is null && state.ErrorKey is not null);
        }
        void Changed(object? sender, PropertyChangedEventArgs args) => RenderSetting();
        toggle.Toggled += (_, _) => RenderSetting();
        pause.Click += (_, _) => { if (state.Paused || state.ErrorKey is not null) state.Resume(); else state.Pause(); };
        retry.Click += async (_, _) => { await state.RefreshSettingsAsync(); RenderSetting(); };
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true; var deferral = args.GetDeferral();
            try { await state.SetEnabledAsync(toggle.IsOn); if (Current() && state.PendingSetting is null && state.ErrorKey is null) dialog.Hide(); }
            finally { deferral.Complete(); RenderSetting(); }
        };
        dialog.Closed += (_, _) => closed = true; state.PropertyChanged += Changed;
        try
        {
            if (MoreButton.Flyout.IsOpen) MoreButton.Flyout.Hide();
            SetPhotoDialog(dialog); var showing = ShowPhotoDialogAsync(dialog); await state.RefreshSettingsAsync(); RenderSetting(); await showing;
        }
        finally { closed = true; state.PropertyChanged -= Changed; state.SettingsVisible = false; if (ReferenceEquals(_dialog, dialog)) SetPhotoDialog(null); }
    }
}
