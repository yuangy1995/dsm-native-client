using LanStash.App.Features.Files.Office;
using LanStash.App.Localization;
using LanStash.App.Platform.Office;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class FilesPage
{
    private OfficeEditingCoordinator? _officeCoordinator;
    private IOfficeEditingRepository? _officeRepository;
    private OfficeDocumentActions _officeActions = new();
    private OfficeEditingDialog? _officeDialog;
    private CancellationTokenSource? _officePageCancellation;
    private ContentDialog? _officeProgress;
    private bool _officeBusy;
    private void InitializeOffice(OfficeEditingCoordinator? coordinator)
    {
        _officeCoordinator = coordinator;
        _officeRepository = _previewRepository is IOfficeEditingRepository office && office.ProfileId == _profileId ? office : null;
        PreviewPane.OfficeActionRequested += OfficeActionRequested;
        PreviewPane.OfficeSessionsRequested += OfficeSessionsRequested;
        if (_officeCoordinator is not null) _officeCoordinator.Changed += OfficeChanged;
        OfficeSessionsButton.Visibility = _officeCoordinator is not null && _officeRepository is not null ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OfficeChanged(object? sender, EventArgs args) => DispatcherQueue.TryEnqueue(UpdateOfficeActions);
    private void UpdateOfficeActions()
    {
        if (_disposed || PreviewPane is null) return;
        PreviewPane.SetOfficeActionsEnabled(!_officeBusy,
            !_officeBusy && _officeCoordinator is not null && _officeRepository?.OfficeAvailability.CanAutoSave == true,
            !_officeBusy && _officeCoordinator is not null && _officeRepository is not null);
        OfficeSessionsButton.IsEnabled = !_officeBusy && _officeDialog is null;
        var session = _officeRepository is { } repository && _previewViewModel.Snapshot.Item is { } item
            ? _officeCoordinator?.SessionFor(repository, item.Path, includeStopped: true) : null;
        PreviewPane.SetOfficeSessionStatus(session is null ? null : session.Phase == OfficeEditingPhase.Saved && session.Info?.SavedAt is { } saved ?
            L.Format("OfficeSavedSummary", saved.ToLocalTime().ToString("g", System.Globalization.CultureInfo.CurrentCulture)) : L.Get(OfficeEditingDialog.PhaseKey(session.Phase)));
    }
    private async void OfficeActionRequested(object? sender, OfficePreviewActionEventArgs args) => await OpenOfficeAsync(args);
    private async Task OpenOfficeAsync(OfficePreviewActionEventArgs args)
    {
        if (_disposed || _officeBusy || args.Target.ProfileId != _profileId || !OfficeDocumentFormat.Supports(args.Target.Item) ||
            _previewViewModel.Snapshot.Item?.Path != args.Target.Item.Path ||
            args.AutoSave && (_officeCoordinator is null || _officeRepository?.OfficeAvailability.CanAutoSave != true)) return;
        _officeBusy = true; UpdateOfficeActions(); PreviewPane.SuspendOfficePreview(true);
        var cancellation = new CancellationTokenSource(); _officePageCancellation = cancellation;
        var item = args.Target.Item;
        try
        {
            var existing = args.AutoSave ? _officeCoordinator!.SessionFor(_officeRepository!, item.Path) : null;
            if (existing is not null)
            {
                if (!await _officeActions.Launcher.OpenAsync(existing.LocalPath, args.ChooseApplication)) throw new IOException("office.open-failed");
                return;
            }
            if (args.AutoSave)
            {
                var confirm = new ContentDialog
                {
                    XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = L.Get("OfficeAutoConfirmTitle"),
                    Content = L.Format("OfficeAutoConfirmDetail", item.Name, item.Path),
                    PrimaryButtonText = L.Get("OfficeAutoStart"), CloseButtonText = L.Get("ActionCancel"), DefaultButton = ContentDialogButton.Close,
                };
                _officeProgress = confirm;
                if (await confirm.ShowAsync() != ContentDialogResult.Primary) return;
                _officeProgress = null;
            }
            cancellation.Token.ThrowIfCancellationRequested();
            var path = await _officeActions.Picker.PickSavePathAsync(item.Name);
            cancellation.Token.ThrowIfCancellationRequested();
            if (path is null || _disposed) return;
            if (!string.Equals(Path.GetExtension(path), Path.GetExtension(item.Name), StringComparison.OrdinalIgnoreCase))
                throw new IOException("office.copy-extension");
            // 用户选择的副本不得进入同一应用管理的云盘根。
            if ((Application.Current as App)?.MainWindow is { } window)
                await window.ValidateOfficeCopyDestinationAsync(args.AutoSave ? _profileId : Guid.Empty, item.Path, path, cancellation.Token);
            var content = new StackPanel { Spacing = 12, MinWidth = 320 };
            content.Children.Add(new ProgressRing { IsActive = true, Width = 36, Height = 36 });
            content.Children.Add(new TextBlock { Text = L.Get("OfficePreparingDetail"), TextWrapping = TextWrapping.Wrap });
            var progress = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme,
                Title = L.Get("OfficePreparing"), Content = content, CloseButtonText = L.Get("ActionCancel") };
            progress.CloseButtonClick += (_, _) => cancellation.Cancel();
            _officeProgress = progress;
            var visible = progress.ShowAsync();
            try
            {
                if (args.AutoSave) await _officeCoordinator!.BeginAsync(_officeRepository!, item, path, cancellation.Token);
                else await _officeActions.SaveReadOnlyCopyAsync(_previewRepository, item, path, cancellation.Token);
            }
            finally { progress.Hide(); await visible; _officeProgress = null; }
            cancellation.Token.ThrowIfCancellationRequested();
            if (!await _officeActions.Launcher.OpenAsync(path, args.ChooseApplication)) throw new IOException("office.open-failed");
        }
        catch (OperationCanceledException) { }
        catch (Exception error)
        {
            if (!_disposed && !cancellation.IsCancellationRequested)
            {
                var message = error.Message switch
                {
                    "office.cloud-local-copy" => "OfficeOutsideCloud",
                    "office.cloud-writeback-conflict" => "OfficeCloudConflict",
                    "office.copy-extension" => "OfficeExtensionMismatch",
                    "office.open-failed" => "OfficeOpenFailed",
                    _ => "OfficeActionFailed",
                };
                await new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = L.Get("OfficeActionFailedTitle"),
                    Content = L.Get(message), CloseButtonText = L.Get("ActionClose") }.ShowAsync();
            }
        }
        finally
        {
            _officeProgress = null; if (ReferenceEquals(_officePageCancellation, cancellation)) _officePageCancellation = null;
            cancellation.Dispose(); _officeBusy = false;
            if (!_disposed) { UpdateOfficeActions(); PreviewPane.SuspendOfficePreview(false); }
        }
    }

    private async void OfficeSessions_Click(object sender, RoutedEventArgs args) => await ShowOfficeSessionsAsync();
    private async void OfficeSessionsRequested(object? sender, EventArgs args) => await ShowOfficeSessionsAsync();
    private async Task ShowOfficeSessionsAsync()
    {
        if (_disposed || _officeBusy || _officeDialog is not null || _officeCoordinator is null || _officeRepository is null) return;
        _officeBusy = true; UpdateOfficeActions(); PreviewPane.SuspendOfficePreview(true);
        var cancellation = new CancellationTokenSource(); _officePageCancellation = cancellation;
        try
        {
            await _officeCoordinator.AttachAsync(_officeRepository, cancellation.Token);
            if (_disposed || cancellation.IsCancellationRequested) return;
            var preferred = _previewViewModel.Snapshot.Item is { } current ? _officeCoordinator.SessionFor(_officeRepository, current.Path, includeStopped: true)?.Id : null;
            using var dialog = new OfficeEditingDialog(_officeCoordinator, _officeRepository, _officeActions, preferred)
                { XamlRoot = XamlRoot, RequestedTheme = ActualTheme };
            _officeDialog = dialog; await dialog.ShowAsync();
        }
        catch (OperationCanceledException) { }
        catch
        {
            if (!_disposed) await new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme,
                Title = L.Get("OfficeSessionsTitle"), Content = L.Get("OfficeStorageUnavailable"), CloseButtonText = L.Get("ActionClose") }.ShowAsync();
        }
        finally
        {
            if (ReferenceEquals(_officePageCancellation, cancellation)) _officePageCancellation = null;
            cancellation.Dispose(); _officeDialog = null; _officeBusy = false;
            if (!_disposed) { UpdateOfficeActions(); PreviewPane.SuspendOfficePreview(false); }
        }
    }
    private static LocalizationService L => LocalizationService.Current;
    private void CancelOfficePageReads()
    { _officePageCancellation?.Cancel(); _officeProgress?.Hide(); _officeDialog?.Hide(); }
    private void DisposeOfficePage()
    {
        CancelOfficePageReads(); _officeDialog?.Dispose();
        if (_officeCoordinator is not null) _officeCoordinator.Changed -= OfficeChanged;
        PreviewPane.OfficeActionRequested -= OfficeActionRequested; PreviewPane.OfficeSessionsRequested -= OfficeSessionsRequested;
    }
}
