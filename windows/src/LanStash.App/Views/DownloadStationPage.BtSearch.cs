using LanStash.App.Localization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace LanStash.App.Views;

public sealed partial class DownloadStationPage
{
    private ContentDialog? _btSearchDialog;

    private async void BtSearch_Click(object sender, RoutedEventArgs e) =>
        await ShowBtSearchDialogAsync();

    private async void BtSearchAccelerator_Invoked(
        KeyboardAccelerator sender,
        KeyboardAcceleratorInvokedEventArgs args)
    {
        if (!_viewModel.HasBtSearchCapability || _btSearchDialog is not null)
        {
            return;
        }
        args.Handled = true;
        await ShowBtSearchDialogAsync();
    }

    private async Task ShowBtSearchDialogAsync()
    {
        if (_disposed ||
            !_viewModel.HasBtSearchCapability ||
            _btSearchDialog is not null)
        {
            return;
        }

        var session = _viewModel.BeginBtSearchSessionAsync();
        ObserveBtSearchTask(session);
        using var content = new DownloadStationBtSearchDialogContent(_viewModel);
        var dialog = _btSearchDialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = LocalizationService.Current.Get("DownloadStationBtSearchDialogTitle"),
            Content = content,
            PrimaryButtonText = LocalizationService.Current.Get("DownloadStationBtSearchSearchAction"),
            SecondaryButtonText = LocalizationService.Current.Get("DownloadStationBtSearchCreateAction"),
            CloseButtonText = LocalizationService.Current.Get("ActionClose"),
            DefaultButton = ContentDialogButton.Primary,
        };
        dialog.PrimaryButtonClick += (_, args) =>
        {
            args.Cancel = true;
            if (!_viewModel.CanSearchBt)
            {
                return;
            }
            ObserveBtSearchTask(_viewModel.SearchBtAsync());
        };
        dialog.SecondaryButtonClick += async (_, args) =>
        {
            if (!_viewModel.CanCreateSelectedBtSearchResult)
            {
                args.Cancel = true;
                return;
            }
            var deferral = args.GetDeferral();
            try
            {
                dialog.IsPrimaryButtonEnabled = false;
                dialog.IsSecondaryButtonEnabled = false;
                await _viewModel.CreateSelectedBtSearchResultAsync();
            }
            finally
            {
                deferral.Complete();
            }
        };
        dialog.Opened += (_, _) => content.FocusKeyword();

        UpdateBtSearchUi();
        try
        {
            _ = await dialog.ShowAsync();
        }
        finally
        {
            _btSearchDialog = null;
            _viewModel.EndBtSearchSession();
            dialog.Content = null;
            UpdateState();
        }
    }

    private void UpdateBtSearchUi()
    {
        BtSearchButton.Visibility = Visible(_viewModel.HasBtSearchCapability);
        BtSearchButton.IsEnabled = _viewModel.HasBtSearchCapability &&
            _btSearchDialog is null;
        if (_btSearchDialog is { } dialog)
        {
            dialog.IsPrimaryButtonEnabled = _viewModel.CanSearchBt;
            dialog.IsSecondaryButtonEnabled = _viewModel.CanCreateSelectedBtSearchResult;
        }
    }

    private void CloseBtSearchDialog()
    {
        _btSearchDialog?.Hide();
        _viewModel.EndBtSearchSession();
    }

    private static void ObserveBtSearchTask(Task task)
    {
        _ = task.ContinueWith(
            static completed =>
            {
                _ = completed.Exception;
            },
            CancellationToken.None,
            TaskContinuationOptions.OnlyOnFaulted |
                TaskContinuationOptions.ExecuteSynchronously,
            TaskScheduler.Default);
    }
}
