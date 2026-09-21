using LanStash.App.Features.Downloads;
using LanStash.App.Localization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class DownloadStationPage
{
    private DownloadTaskBatchViewModel? _taskBatch;
    private ContentDialog? _batchDialog;
    private async void Batch_Click(object sender, RoutedEventArgs e)
    {
        if (_disposed || _batchDialog is not null || XamlRoot is null) return;
        _taskBatch ??= new(_repository);
        var model = _taskBatch; var load = model.LoadAsync();
        using var content = new DownloadTaskBatchDialogContent(model);
        var dialog = _batchDialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Content = content,
            Title = LocalizationService.Current.Get("DownloadBatchTitle"), PrimaryButtonText = content.PrimaryText,
            CloseButtonText = LocalizationService.Current.Get("DownloadSettingsClose"), DefaultButton = ContentDialogButton.Close,
            PrimaryButtonStyle = content.ActionButtonStyle, CloseButtonStyle = content.ActionButtonStyle };
        void Update() { dialog.PrimaryButtonText = content.PrimaryText; dialog.IsPrimaryButtonEnabled = content.CanSubmit; }
        async void Submit(ContentDialog sender, ContentDialogButtonClickEventArgs args)
        { args.Cancel = true; var deferral = args.GetDeferral(); try { await content.SubmitAsync(); } finally { Update(); deferral.Complete(); } }
        void Closing(ContentDialog sender, ContentDialogClosingEventArgs args) { if (model.IsBusy && !_disposed) args.Cancel = true; }
        content.StateChanged += Update; dialog.PrimaryButtonClick += Submit; dialog.Closing += Closing; Update();
        try { await dialog.ShowAsync(); }
        finally
        {
            content.StateChanged -= Update; dialog.PrimaryButtonClick -= Submit; dialog.Closing -= Closing;
            model.CancelLoading(); await load; _batchDialog = null;
            if (!_disposed)
            {
                _viewModel.ApplyConfirmedBatchResults(_repository.ProfileId, model.ConfirmedTasks, model.RemovedTaskIds);
                model.ClearAppliedResults(); UpdateState(); await RunAsync(_viewModel.RefreshAsync);
            }
        }
    }
    private void DisposeTaskBatch() { _batchDialog?.Hide(); _batchDialog = null; _taskBatch?.Dispose(); _taskBatch = null; }
}
