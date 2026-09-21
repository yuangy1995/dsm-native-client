using LanStash.App.CloudDrive;
using LanStash.App.Localization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

internal sealed class CloudDriveWritebackDialog : ContentDialog
{
    private readonly Func<CancellationToken, Task<CloudDriveWritebackOverview>> _read;
    private readonly Func<bool, bool, CancellationToken, Task<CloudDriveWritebackPreparation>> _configure;
    private readonly Func<CloudDrivePendingChange, CloudDriveRecoveryAction, bool, CancellationToken, Task> _recover;
    private readonly Func<CloudDrivePendingChange, CancellationToken, Task<bool>> _export;
    private readonly Func<bool> _current;
    private readonly Func<CloudDriveRelocationOperation, CloudDriveRelocationRecoveryAction, bool, CancellationToken, Task>? _relocate;
    private readonly Func<bool, bool, CancellationToken, Task>? _configureDeletion;
    private readonly Func<CloudDriveDeletionOperation, CloudDriveDeletionRecoveryAction, bool, CancellationToken, Task>? _delete;
    private readonly bool _canEnable;
    private readonly CancellationTokenSource _lifetime = new();
    private readonly StackPanel _content = new() { Spacing = 12 };
    private readonly ContentControl _host = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch };
    private readonly StackPanel _records = new() { Spacing = 12 };
    private readonly TextBlock _mode = new() { TextWrapping = TextWrapping.Wrap };
    private readonly TextBlock _message = new() { TextWrapping = TextWrapping.Wrap };
    private readonly CheckBox _confirmation = new() { Name = "WritebackModeConfirmation", MinHeight = 44, IsChecked = false,
        HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch };
    private readonly Button _modeButton = new() { Name = "WritebackModeButton", MinHeight = 44 };
    private readonly CheckBox _deleteConfirmation = new() { Name = "DeletionModeConfirmation", MinHeight = 44, IsChecked = false,
        HorizontalContentAlignment = HorizontalAlignment.Stretch };
    private readonly Button _deleteModeButton = new() { Name = "DeletionModeButton", MinHeight = 44, IsEnabled = false };
    private CloudDriveWritebackOverview? _overview;
    private bool _open;
    private bool Current => _open && _current() && !_lifetime.IsCancellationRequested;
    private static LocalizationService L => LocalizationService.Current;

    internal CloudDriveWritebackDialog(Func<CancellationToken, Task<CloudDriveWritebackOverview>> read,
        Func<bool, bool, CancellationToken, Task<CloudDriveWritebackPreparation>> configure,
        Func<CloudDrivePendingChange, CloudDriveRecoveryAction, bool, CancellationToken, Task> recover,
        Func<CloudDrivePendingChange, CancellationToken, Task<bool>> export, Func<bool> current, bool canEnable,
        Func<CloudDriveRelocationOperation, CloudDriveRelocationRecoveryAction, bool, CancellationToken, Task>? relocate = null,
        Func<bool, bool, CancellationToken, Task>? configureDeletion = null,
        Func<CloudDriveDeletionOperation, CloudDriveDeletionRecoveryAction, bool, CancellationToken, Task>? delete = null)
    {
        _read = read; _configure = configure; _recover = recover; _export = export; _current = current; _canEnable = canEnable;
        _relocate = relocate;
        _configureDeletion = configureDeletion; _delete = delete;
        Title = L.Get("CloudDriveWritebackTitle"); CloseButtonText = L.Get("ActionClose"); DefaultButton = ContentDialogButton.Close;
        _modeButton.IsEnabled = false;
        _confirmation.IsEnabled = false;
        var refresh = new Button { Content = L.Get("ActionRefresh.Label"), MinHeight = 44 };
        refresh.Click += async (_, _) => await RunAsync(_ => Task.FromResult(L.Get("CloudDriveWritebackUpdated")));
        _confirmation.Checked += (_, _) => UpdateModeButton();
        _confirmation.Unchecked += (_, _) => UpdateModeButton();
        _modeButton.Click += async (_, _) =>
        {
            if (_overview is null || _confirmation.IsChecked != true || !Current) return;
            var enable = !_overview.Enabled;
            await RunAsync(async token =>
            {
                var result = await _configure(enable, true, token);
                return enable ? L.Format("CloudDriveWritebackPrepared", result.Ready, result.Unavailable) : L.Get("CloudDriveWritebackDisabled");
            });
        };
        _content.Children.Add(_mode);
        _content.Children.Add(_confirmation);
        _content.Children.Add(_modeButton);
        _deleteConfirmation.Checked += (_, _) => _deleteModeButton.IsEnabled = _overview?.Enabled == true && _canEnable && _configureDeletion is not null;
        _deleteConfirmation.Unchecked += (_, _) => _deleteModeButton.IsEnabled = false;
        _deleteModeButton.Click += async (_, _) =>
        {
            if (_deleteConfirmation.IsChecked != true || _overview is null || _configureDeletion is null) return;
            var enabled = !_overview.DeletionEnabled;
            await RunAsync(async token => { await _configureDeletion(enabled, true, token); return L.Get("CloudDriveWritebackUpdated"); });
        };
        _content.Children.Add(_deleteConfirmation); _content.Children.Add(_deleteModeButton);
        _content.Children.Add(refresh);
        _content.Children.Add(_message);
        _content.Children.Add(_records);
        _host.Content = _content;
        Content = new ScrollViewer { MaxHeight = 540, Content = _host, Padding = new Thickness(0, 0, 16, 0),
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        Opened += async (_, _) => { _open = true; await RunAsync(_ => Task.FromResult("")); };
        Closed += (_, _) => { _open = false; _lifetime.Cancel(); };
    }

    private void UpdateModeButton() => _modeButton.IsEnabled = _overview is not null && _confirmation.IsChecked == true && (_overview.Enabled || _canEnable);

    private async Task RunAsync(Func<CancellationToken, Task<string>> action)
    {
        if (!Current || !_host.IsEnabled) return;
        _host.IsEnabled = false;
        _message.Text = L.Get("CloudDriveWritebackWorking");
        try
        {
            var message = await action(_lifetime.Token);
            if (!Current) return;
            var overview = await _read(_lifetime.Token);
            if (!Current) return;
            _overview = overview; Render(); _message.Text = message;
        }
        catch (OperationCanceledException) { if (Current) _message.Text = L.Get("CloudDriveWritebackCancelled"); }
        catch (Exception error)
        {
            if (Current) _message.Text = L.Get(ErrorKey(error));
        }
        finally { if (Current) _host.IsEnabled = true; }
    }

    private void Render()
    {
        var overview = _overview!;
        _mode.Text = L.Get(!_canEnable ? "CloudDriveWritebackFolderOnly" : overview.Enabled ? "CloudDriveWritebackEnabled" : "CloudDriveWritebackReadOnly");
        _confirmation.Content = new TextBlock { Text = L.Get(overview.Enabled ? "CloudDriveWritebackDisableConfirm" : "CloudDriveWritebackEnableConfirm"), TextWrapping = TextWrapping.Wrap };
        _confirmation.IsChecked = false;
        _confirmation.IsEnabled = overview.Enabled || _canEnable;
        _modeButton.Content = L.Get(overview.Enabled ? "CloudDriveWritebackDisable" : "CloudDriveWritebackEnable");
        UpdateModeButton();
        _deleteConfirmation.Content = new TextBlock { Text = L.Get(overview.DeletionEnabled ? "CloudDriveDeletionDisableConfirm" : "CloudDriveDeletionEnableConfirm"), TextWrapping = TextWrapping.Wrap };
        _deleteConfirmation.IsChecked = false;
        _deleteConfirmation.IsEnabled = overview.Enabled && _canEnable && _configureDeletion is not null;
        _deleteModeButton.Content = L.Get(overview.DeletionEnabled ? "CloudDriveDeletionDisable" : "CloudDriveDeletionEnable");
        _deleteModeButton.IsEnabled = false;
        _records.Children.Clear();
        var rows = overview.Changes.Where(item => item.IsPending).OrderByDescending(item => item.CreatedAt)
            .Concat(overview.Changes.Where(item => !item.IsPending).OrderByDescending(item => item.CreatedAt).Take(10)).ToArray();
        var relocations = (overview.Relocations ?? []).Where(item => item.IsPending).OrderBy(item => item.CreatedAt).ToArray();
        var deletions = (overview.Deletions ?? []).Where(item => item.IsPending).OrderBy(item => item.CreatedAt).ToArray();
        _records.Children.Add(new TextBlock { Text = L.Get(rows.Length == 0 && relocations.Length == 0 && deletions.Length == 0 ? "CloudDriveWritebackEmpty" : "CloudDriveWritebackHistory"), TextWrapping = TextWrapping.Wrap });
        foreach (var operation in deletions)
        {
            var row = new StackPanel { Spacing = 6 };
            row.Children.Add(new TextBlock { Text = operation.RemotePath, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true });
            row.Children.Add(new TextBlock { Text = L.Get(operation.Phase switch
            {
                CloudDriveDeletionPhase.Prepared => "CloudDriveDeletionPrepared",
                CloudDriveDeletionPhase.Submitted => "CloudDriveDeletionUnknown",
                _ => "CloudDriveDeletionLocalPending",
            }), TextWrapping = TextWrapping.Wrap });
            var confirm = new CheckBox { MinHeight = 44, Tag = operation.Id, IsChecked = false, HorizontalContentAlignment = HorizontalAlignment.Stretch,
                Content = new TextBlock { Text = L.Get(operation.IsDirectory ? "CloudDriveDeletionDirectoryConfirm" : "CloudDriveDeletionFileConfirm"), TextWrapping = TextWrapping.Wrap } };
            row.Children.Add(confirm);
            void Add(string key, CloudDriveDeletionRecoveryAction action)
            {
                var button = new Button { Content = L.Get(key), MinHeight = 44, IsEnabled = false, Tag = operation.Id };
                confirm.Checked += (_, _) => button.IsEnabled = _delete is not null;
                confirm.Unchecked += (_, _) => button.IsEnabled = false;
                button.Click += async (_, _) =>
                {
                    if (confirm.IsChecked != true || _delete is null) return;
                    await RunAsync(async token => { await _delete(operation, action, true, token); return L.Get("CloudDriveWritebackUpdated"); });
                };
                row.Children.Add(button);
            }
            if (operation.Phase == CloudDriveDeletionPhase.Prepared)
            {
                Add("CloudDriveDeletionConfirm", CloudDriveDeletionRecoveryAction.Confirm);
                Add("CloudDriveDeletionAbandon", CloudDriveDeletionRecoveryAction.Abandon);
            }
            if (operation.Phase == CloudDriveDeletionPhase.Submitted) Add("CloudDriveWritebackReview", CloudDriveDeletionRecoveryAction.Review);
            if (operation.Phase == CloudDriveDeletionPhase.ServerVerified) Add("CloudDriveDeletionCompleteLocal", CloudDriveDeletionRecoveryAction.CompleteLocal);
            _records.Children.Add(row);
        }
        foreach (var operation in relocations)
        {
            var row = new StackPanel { Spacing = 6 };
            row.Children.Add(new TextBlock { Text = L.Format("CloudDriveRelocationPaths", operation.Source, operation.Destination), TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true });
            row.Children.Add(new TextBlock { Text = L.Get(RelocationPhaseKey(operation.Phase)), TextWrapping = TextWrapping.Wrap });
            if (operation.Step < operation.Steps.Count)
            {
                var step = operation.Steps[operation.Step];
                row.Children.Add(new TextBlock { Text = L.Format("CloudDriveRelocationStep", step.Source, step.Destination), TextWrapping = TextWrapping.Wrap });
            }
            var confirm = new CheckBox { IsChecked = false, MinHeight = 44, Tag = operation.Id, HorizontalContentAlignment = HorizontalAlignment.Stretch,
                Content = new TextBlock { Text = L.Get("CloudDriveRelocationConfirm"), TextWrapping = TextWrapping.Wrap } };
            row.Children.Add(confirm);
            void Add(string key, CloudDriveRelocationRecoveryAction action)
            {
                var button = new Button { Content = L.Get(key), MinHeight = 44, IsEnabled = false, Tag = operation.Id };
                confirm.Checked += (_, _) => button.IsEnabled = _relocate is not null;
                confirm.Unchecked += (_, _) => button.IsEnabled = false;
                button.Click += async (_, _) =>
                {
                    if (confirm.IsChecked != true || _relocate is null) return;
                    await RunAsync(async token => { await _relocate(operation, action, true, token); return L.Get("CloudDriveWritebackUpdated"); });
                };
                row.Children.Add(button);
            }
            if (operation.Phase == CloudDriveRelocationPhase.Submitted) Add("CloudDriveWritebackReview", CloudDriveRelocationRecoveryAction.Review);
            if (operation.Phase is CloudDriveRelocationPhase.Prepared or CloudDriveRelocationPhase.Rejected or CloudDriveRelocationPhase.ReadyForNextStep)
                Add("CloudDriveRelocationContinue", CloudDriveRelocationRecoveryAction.Continue);
            if (operation.Phase == CloudDriveRelocationPhase.ServerVerified) Add("CloudDriveRelocationCompleteLocal", CloudDriveRelocationRecoveryAction.CompleteLocal);
            if (operation.Step == 0 && operation.Phase is CloudDriveRelocationPhase.Prepared or CloudDriveRelocationPhase.Rejected)
                Add("CloudDriveRelocationAbandon", CloudDriveRelocationRecoveryAction.Abandon);
            _records.Children.Add(row);
        }
        foreach (var change in rows)
        {
            var directory = change.Kind == CloudDriveChangeKind.CreateDirectory;
            var row = new StackPanel { Spacing = 6 };
            row.Children.Add(new TextBlock { Text = change.RemotePath, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true });
            row.Children.Add(new TextBlock { Text = L.Format(directory ? "CloudDriveCreationRecorded" : "CloudDriveWritebackCaptured", change.CreatedAt.LocalDateTime), TextWrapping = TextWrapping.Wrap });
            row.Children.Add(new TextBlock { Text = L.Get(directory ? DirectoryPhaseKey(change.Phase) : PhaseKey(change.Phase)), TextWrapping = TextWrapping.Wrap });
            var confirm = new CheckBox { MinHeight = 44, Tag = change.Id, IsChecked = false,
                HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch, Content = new TextBlock
                { Text = L.Get(directory ? "CloudDriveDirectoryRecoveryConfirm" : "CloudDriveWritebackRecoveryConfirm"), TextWrapping = TextWrapping.Wrap } };
            if (change.Phase is CloudDriveChangePhase.Conflict or CloudDriveChangePhase.Rejected or CloudDriveChangePhase.KeptLocally) row.Children.Add(confirm);
            if (directory && change.Phase == CloudDriveChangePhase.Submitted) row.Children.Add(confirm);
            void Add(string key, CloudDriveRecoveryAction action, bool needsConfirmation, bool requiresEnabled)
            {
                var button = new Button { Content = L.Get(key), MinHeight = 44, Tag = change.Id,
                    IsEnabled = !needsConfirmation && (!requiresEnabled || overview.Enabled) };
                if (needsConfirmation)
                {
                    confirm.Checked += (_, _) => button.IsEnabled = !requiresEnabled || overview.Enabled;
                    confirm.Unchecked += (_, _) => button.IsEnabled = false;
                }
                button.Click += async (_, _) =>
                {
                    if (needsConfirmation && confirm.IsChecked != true) return;
                    await RunAsync(async token => { await _recover(change, action, needsConfirmation, token); return L.Get("CloudDriveWritebackUpdated"); });
                };
                row.Children.Add(button);
            }
            if (change.Phase == CloudDriveChangePhase.Submitted) Add("CloudDriveWritebackReview", CloudDriveRecoveryAction.Review, directory, false);
            if (change.Phase == CloudDriveChangePhase.Prepared) Add(directory ? "CloudDriveCreateDirectoryNow" : "CloudDriveWritebackSave", CloudDriveRecoveryAction.Save, false, true);
            if (change.Phase is CloudDriveChangePhase.Conflict or CloudDriveChangePhase.Rejected or CloudDriveChangePhase.KeptLocally)
            {
                Add(directory ? "CloudDriveRetryDirectory" : "CloudDriveWritebackRetry", CloudDriveRecoveryAction.Retry, true, true);
                if (change.Phase != CloudDriveChangePhase.KeptLocally) Add("CloudDriveWritebackKeep", CloudDriveRecoveryAction.KeepLocal, true, false);
            }
            if (change.Phase == CloudDriveChangePhase.Prepared)
            {
                row.Children.Add(confirm);
                Add("CloudDriveWritebackKeep", CloudDriveRecoveryAction.KeepLocal, true, false);
            }
            if (change.ContentReleased)
                row.Children.Add(new TextBlock { Text = L.Get("CloudDriveWritebackCopyReleased"), TextWrapping = TextWrapping.Wrap });
            if (!directory && !change.ContentReleased)
            {
                var export = new Button { Content = L.Get("CloudDriveWritebackExport"), MinHeight = 44, Tag = change.Id };
                export.Click += async (_, _) => await RunAsync(async token =>
                    await _export(change, token) ? L.Get("CloudDriveWritebackExported") : L.Get("CloudDriveWritebackCancelled"));
                row.Children.Add(export);
            }
            _records.Children.Add(new Border { Padding = new Thickness(10), BorderThickness = new Thickness(1),
                BorderBrush = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["CardStrokeColorDefaultBrush"], CornerRadius = new CornerRadius(8), Child = row });
        }
    }

    private static string RelocationPhaseKey(CloudDriveRelocationPhase phase) => phase switch
    {
        CloudDriveRelocationPhase.Prepared => "CloudDriveRelocationPrepared",
        CloudDriveRelocationPhase.Submitted => "CloudDriveRelocationUnknown",
        CloudDriveRelocationPhase.ReadyForNextStep => "CloudDriveRelocationNextStep",
        CloudDriveRelocationPhase.ServerVerified => "CloudDriveRelocationLocalPending",
        CloudDriveRelocationPhase.Rejected => "CloudDriveRelocationRejected",
        _ => "CloudDriveWritebackError",
    };

    private static string DirectoryPhaseKey(CloudDriveChangePhase phase) => phase switch
    {
        CloudDriveChangePhase.Prepared => "CloudDriveDirectoryPrepared",
        CloudDriveChangePhase.Submitted => "CloudDriveDirectoryUnknown",
        CloudDriveChangePhase.Conflict => "CloudDriveDirectoryConflict",
        CloudDriveChangePhase.Rejected => "CloudDriveDirectoryRejected",
        CloudDriveChangePhase.Verified => "CloudDriveDirectoryCreated",
        CloudDriveChangePhase.KeptLocally => "CloudDriveDirectoryKept",
        _ => "CloudDriveWritebackError",
    };

    private static string PhaseKey(CloudDriveChangePhase phase) => phase switch
    {
        CloudDriveChangePhase.Prepared => "CloudDriveChangePrepared",
        CloudDriveChangePhase.Submitted => "CloudDriveChangeSubmitted",
        CloudDriveChangePhase.Conflict => "CloudDriveChangeConflict",
        CloudDriveChangePhase.Rejected => "CloudDriveChangeRejected",
        CloudDriveChangePhase.Verified => "CloudDriveChangeVerified",
        CloudDriveChangePhase.KeptLocally => "CloudDriveChangeKeptLocally",
        _ => "CloudDriveWritebackError",
    };

    private static string ErrorKey(Exception error) => error.Message switch
    {
        "CloudDriveResumeBeforeWriteback" => "CloudDriveResumeBeforeWriteback",
        "CloudDriveWritebackPending" or "cloud.sync.pending_changes" => "CloudDriveWritebackPending",
        "CloudDriveWritebackChanged" or "cloud.sync.invalid_transition" => "CloudDriveWritebackChanged",
        "CloudDriveExportOutsideMapping" or "cloud.sync.protected_destination" => "CloudDriveExportOutsideMapping",
        "cloud.sync.directory_conflict" => "CloudDriveDirectoryConflict",
        "cloud.sync.parent_pending" => "CloudDriveParentPending",
        "cloud.relocate.pending" or "cloud.relocate.result_unknown" => "CloudDriveRelocationUnknown",
        "cloud.relocate.destination_exists" or "cloud.relocate.local_unverified" => "CloudDriveRelocationConflict",
        "cloud.delete.result_unknown" or "cloud.delete.pending" => "CloudDriveDeletionUnknown",
        "cloud.delete.target_changed" or "cloud.delete.identity_changed" or "cloud.delete.state_changed" => "CloudDriveWritebackChanged",
        "cloud.sync.content_released" => "CloudDriveWritebackCopyReleased",
        _ => "CloudDriveWritebackError",
    };
}
