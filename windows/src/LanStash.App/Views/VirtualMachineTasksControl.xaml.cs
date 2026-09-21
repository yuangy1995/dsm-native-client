using LanStash.App.Features.VirtualMachines;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class VirtualMachineTasksControl : UserControl, IDisposable
{
    private readonly VirtualMachineTasksViewModel _model = new();
    private bool _disposed;
    private ContentDialog? _cleanupDialog;
    public VirtualMachineTasksControl()
    {
        InitializeComponent(); TaskList.ItemsSource = _model.Tasks;
        _model.PropertyChanged += (_, _) => DispatcherQueue.TryEnqueue(UpdateState);
        Unloaded += async (_, _) => { _cleanupDialog?.Hide(); await _model.SetVisibleAsync(false); };
        UpdateState();
    }
    public Task ActivateAsync(IVirtualMachineManagerRepository repository) => _model.ActivateAsync(repository);
    public Task SetVisibleAsync(bool visible) => _model.SetVisibleAsync(visible);
    public Task RefreshAsync() => _model.RefreshAsync();
    private async void Refresh_Click(object sender, RoutedEventArgs e) => await _model.RefreshAsync();
    private async void ReviewClear_Click(object sender, RoutedEventArgs e) => await _model.ReviewCleanupAsync();
    private async void Clear_Click(object sender, RoutedEventArgs e) => await ShowCleanupAsync();
    private async Task ShowCleanupAsync()
    {
        if (_disposed || _cleanupDialog is not null || XamlRoot is null || _model.BeginCleanupConfirmation() is not { } request) return;
        var l = LocalizationService.Current;
        var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, DefaultButton = ContentDialogButton.Close,
            Title = l.Get("VmTasksClearTitle"), PrimaryButtonText = l.Get("VmTasksClearAction"), CloseButtonText = l.Get("ActionClose") };
        _cleanupDialog = dialog;
        void Render()
        {
            if (_disposed || _cleanupDialog != dialog) return;
            dialog.IsPrimaryButtonEnabled = _model.CanSubmitCleanup;
            if (_model.LastCleanup is not null || _model.CleanupMessageKey is not null) dialog.PrimaryButtonText = string.Empty;
            var panel = new StackPanel { Width = 460, MaxWidth = 460, Spacing = 12 };
            panel.Children.Add(new TextBlock { Text = l.Format("VmTasksClearConfirm", request.Keys.Count), TextWrapping = TextWrapping.Wrap });
            if (_model.IsCleaning) panel.Children.Add(new ProgressRing { IsActive = true, Width = 36, Height = 36 });
            if (_model.LastCleanup is { } result) panel.Children.Add(new TextBlock { Text = FormatCleanup(result), TextWrapping = TextWrapping.Wrap });
            if (_model.CleanupMessageKey is { } key) panel.Children.Add(new TextBlock { Text = l.Get(key), TextWrapping = TextWrapping.Wrap });
            dialog.Content = panel;
        }
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true; var deferral = args.GetDeferral();
            try { var operation = _model.SubmitCleanupAsync(); Render(); await operation; Render(); }
            finally { deferral.Complete(); }
        };
        dialog.Closing += (_, _) => _model.EndCleanupConfirmation();
        Render();
        try { await dialog.ShowAsync(); }
        finally { if (_cleanupDialog == dialog) _cleanupDialog = null; _model.EndCleanupConfirmation(); }
        if (!_disposed) await _model.RefreshAsync();
    }
    private static string FormatCleanup(VirtualMachineTaskCleanupResult result)
    {
        var l = LocalizationService.Current;
        var summary = l.Format("VmTasksClearSummary", result.SelectedCount, result.ClearedCount, result.FailedCount, result.NeedsReviewCount, result.NotStartedCount);
        if (result.ErrorCategory == MutationErrorCategory.Authentication) return summary + Environment.NewLine + l.Get("VmTasksReconnect");
        if (result.NeedsReviewCount > 0) return summary + Environment.NewLine + l.Get("VmTasksClearUnknown");
        if (result.NotStartedCount > 0 && result.ErrorCategory == MutationErrorCategory.Conflict) return summary + Environment.NewLine + l.Get("VmTasksClearChanged");
        if (result.FailedCount > 0 || result.ErrorCategory is not null && result.ClearedCount != result.SelectedCount) return summary + Environment.NewLine + l.Get("VmTasksClearFailed");
        return summary;
    }
    private void UpdateState()
    {
        if (_disposed) return;
        RefreshButton.IsEnabled = _model.CanRefresh;
        ClearButton.IsEnabled = _model.CanPrepareCleanup;
        ClearButton.Visibility = Visible(_model.ClearableCount > 0);
        ReviewClearButton.IsEnabled = _model.CanReviewCleanup;
        ReviewClearButton.Visibility = Visible(_model.CleanupRecoveries.Count > 0);
        CleanupStatus.IsOpen = _model.LastCleanup is not null || _model.CleanupMessageKey is not null;
        CleanupStatus.Message = _model.CleanupMessageKey is { } key ? LocalizationService.Current.Get(key) : _model.LastCleanup is { } cleanup ? FormatCleanup(cleanup) : string.Empty;
        CleanupStatus.Severity = _model.LastCleanup is { } done && done.ClearedCount == done.SelectedCount ? InfoBarSeverity.Success : InfoBarSeverity.Warning;
        RefreshError.IsOpen = _model.RequiresReconnect || _model.HasReadFailures || _model.HasError && _model.HasLoaded;
        RefreshError.Message = LocalizationService.Current.Get(_model.RequiresReconnect ? "VmTasksReconnect" : _model.HasError ? "VmTasksRefreshError" : "VmTasksPartialError");
        LoadingState.IsActive = _model.IsLoading && !_model.HasLoaded; LoadingState.Visibility = Visible(LoadingState.IsActive);
        TaskList.Visibility = Visible(_model.HasLoaded && !_model.IsUnavailable);
        EmptyState.Visibility = Visible(_model.HasLoaded && _model.Tasks.Count == 0);
        ErrorState.Visibility = Visible(_model.HasError && !_model.HasLoaded);
        UnavailableState.Visibility = Visible(_model.IsUnavailable);
    }
    private static Visibility Visible(bool value) => value ? Visibility.Visible : Visibility.Collapsed;
    public void Dispose() { if (_disposed) return; _disposed = true; _cleanupDialog?.Hide(); _cleanupDialog = null; _model.Dispose(); }
}
