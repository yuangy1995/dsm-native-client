using LanStash.App.Features.Files.Office;
using LanStash.App.Localization;
using LanStash.App.Platform.Office;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

internal sealed class OfficeEditingDialog : ContentDialog, IDisposable
{
    private readonly OfficeEditingCoordinator _coordinator;
    private readonly IOfficeEditingRepository _repository;
    private readonly OfficeDocumentActions _actions;
    private readonly Guid? _preferredSession;
    private readonly LocalizationService _l = LocalizationService.Current;
    private readonly ListView _list = new() { DisplayMemberPath = "Item.Name", MaxHeight = 150, SelectionMode = ListViewSelectionMode.Single };
    private readonly TextBlock _empty = new() { TextWrapping = TextWrapping.Wrap, Margin = new(0, 16, 0, 16) };
    private readonly TextBlock _status = new() { TextWrapping = TextWrapping.Wrap, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold };
    private readonly TextBlock _detail = new() { TextWrapping = TextWrapping.Wrap };
    private readonly TextBlock _saved = new() { TextWrapping = TextWrapping.Wrap };
    private readonly InfoBar _message = new() { IsClosable = true };
    private readonly StackPanel _selected = new() { Spacing = 10 };
    private readonly StackPanel _confirmation = new() { Spacing = 8, Visibility = Visibility.Collapsed };
    private readonly Button _continue, _review, _stop;
    private readonly List<Button> _buttons = [];
    private IReadOnlyList<OfficeEditingSession> _items = [];
    private OfficeEditingSession? _stopping;
    private bool _disposed, _running;
    public OfficeEditingDialog(OfficeEditingCoordinator coordinator, IOfficeEditingRepository repository, OfficeDocumentActions actions, Guid? preferredSession = null)
    {
        _coordinator = coordinator; _repository = repository; _actions = actions; _preferredSession = preferredSession;
        Title = _l.Get("OfficeSessionsTitle"); CloseButtonText = _l.Get("ActionClose"); DefaultButton = ContentDialogButton.Close;
        AutomationProperties.SetAutomationId(this, "OfficeSessionsDialog");
        AutomationProperties.SetAutomationId(_list, "OfficeSessionList");
        AutomationProperties.SetAutomationId(_status, "OfficeSessionStatus");
        AutomationProperties.SetAutomationId(_confirmation, "OfficeEndConfirmation");
        AutomationProperties.SetName(_list, _l.Get("OfficeSessionsList"));
        AutomationProperties.SetLiveSetting(_status, AutomationLiveSetting.Polite);
        var root = new StackPanel { Spacing = 12, MinWidth = 320, MaxWidth = 720 };
        _empty.Text = _l.Get("OfficeSessionsEmpty");
        root.Children.Add(_list); root.Children.Add(_empty); root.Children.Add(_selected); root.Children.Add(_message);
        _selected.Children.Add(_status); _selected.Children.Add(_detail); _selected.Children.Add(_saved);
        var copies = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        Add(copies, "OfficeOpenCopy", async session => RequireOpened(await _actions.Launcher.OpenAsync(session.LocalPath, false)));
        Add(copies, "OfficeOpenWith", async session => RequireOpened(await _actions.Launcher.OpenAsync(session.LocalPath, true)));
        Add(copies, "OfficeShowCopy", async session => RequireOpened(await _actions.Launcher.RevealAsync(session.LocalPath)));
        _selected.Children.Add(copies);
        var controls = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        Add(controls, "OfficeSaveAs", async session =>
        {
            var path = await _actions.Picker.PickSavePathAsync(session.Item.Name);
            if (path is not null) await _coordinator.ExportAsync(session, path);
        });
        _continue = Add(controls, "OfficeContinue", session => _coordinator.ResumeAsync(session));
        _review = Add(controls, "OfficeRefresh", session => _coordinator.ReviewAsync(session));
        _stop = Add(controls, "OfficeEnd", session => { _stopping = session; _confirmation.Visibility = Visibility.Visible; return Task.CompletedTask; });
        _selected.Children.Add(controls);
        _confirmation.Children.Add(new TextBlock { Text = _l.Get("OfficeEndDetail"), TextWrapping = TextWrapping.Wrap });
        var confirmButtons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var confirm = new Button { Content = _l.Get("OfficeEnd"), MinHeight = 44 };
        AutomationProperties.SetAutomationId(confirm, "OfficeEndConfirm");
        confirm.Click += async (_, _) => { if (_stopping is { } session) await RunAsync(() => _coordinator.StopAsync(session)); _stopping = null; _confirmation.Visibility = Visibility.Collapsed; };
        var cancel = new Button { Content = _l.Get("ActionCancel"), MinHeight = 44 };
        cancel.Click += (_, _) => { _stopping = null; _confirmation.Visibility = Visibility.Collapsed; };
        confirmButtons.Children.Add(confirm); confirmButtons.Children.Add(cancel); _confirmation.Children.Add(confirmButtons);
        _selected.Children.Add(_confirmation);
        Content = new ScrollViewer { Content = root, MaxHeight = 530, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        _list.SelectionChanged += (_, _) => { _stopping = null; _confirmation.Visibility = Visibility.Collapsed; UpdateDetail(); };
        _coordinator.Changed += Changed;
        Closed += (_, _) => Dispose();
        Refresh();
    }

    private Button Add(StackPanel panel, string key, Func<OfficeEditingSession, Task> action)
    {
        var button = new Button { Content = _l.Get(key), MinHeight = 44 };
        AutomationProperties.SetAutomationId(button, key);
        button.Click += async (_, _) => { if (_list.SelectedItem is OfficeEditingSession session) await RunAsync(() => action(session)); };
        panel.Children.Add(button); _buttons.Add(button); return button;
    }
    private static void RequireOpened(bool value) { if (!value) throw new IOException("office.open-failed"); }
    private async Task RunAsync(Func<Task> action)
    {
        if (_running || _disposed) return;
        _running = true; _message.IsOpen = false; UpdateDetail();
        try { await action(); }
        catch
        {
            if (!_disposed)
            { _message.Message = _l.Get("OfficeActionFailed"); _message.Severity = InfoBarSeverity.Error; _message.IsOpen = true; }
        }
        finally { _running = false; if (!_disposed) UpdateDetail(); }
    }
    private void Changed(object? sender, EventArgs args) => DispatcherQueue.TryEnqueue(Refresh);
    private void Refresh()
    {
        if (_disposed) return;
        var items = _coordinator.Sessions.Where(session => session.Repository.ProfileId == _repository.ProfileId &&
            session.Repository.OfficeOwnerId == _repository.OfficeOwnerId).OrderBy(session => session.Info?.State == OfficeEditingState.Stopped).ToArray();
        if (!_items.SequenceEqual(items))
        {
            var selected = (_list.SelectedItem as OfficeEditingSession)?.Id ?? _preferredSession;
            _items = items; _list.ItemsSource = items;
            _list.SelectedItem = items.FirstOrDefault(item => item.Id == selected) ?? items.FirstOrDefault();
        }
        _empty.Visibility = items.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        _list.Visibility = items.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        UpdateDetail();
    }
    private void UpdateDetail()
    {
        if (_disposed) return;
        if (_list.SelectedItem is not OfficeEditingSession session) { _selected.Visibility = Visibility.Collapsed; return; }
        _selected.Visibility = Visibility.Visible;
        _status.Text = _l.Get(PhaseKey(session.Phase));
        var detailKey = session.StorageUnavailable ? "OfficeStorageUnavailable" : !session.Connected ? "OfficeDisconnected" :
            session.LocalUnavailable ? "OfficeLocalUnavailable" : session.Info?.Error == MutationErrorCategory.Permission ? "OfficePermissionDetail" : session.Phase switch
            {
                OfficeEditingPhase.Conflict => "OfficeConflictDetail",
                OfficeEditingPhase.ResultUnavailable => "OfficeUnknownDetail",
                OfficeEditingPhase.Paused => "OfficePausedDetail",
                OfficeEditingPhase.Stopped => "OfficeStoppedDetail",
                _ => null,
            };
        _detail.Text = detailKey is null ? string.Empty : _l.Get(detailKey);
        _detail.Visibility = detailKey is null ? Visibility.Collapsed : Visibility.Visible;
        _saved.Text = session.Info?.SavedAt is { } saved ? _l.Format("OfficeLastSaved", saved.ToLocalTime().ToString("g", System.Globalization.CultureInfo.CurrentCulture)) : string.Empty;
        foreach (var button in _buttons) button.IsEnabled = !_running && !session.Busy && session.Phase != OfficeEditingPhase.Preparing;
        _continue.Visibility = session.CanResume ? Visibility.Visible : Visibility.Collapsed;
        _review.Visibility = session.Phase == OfficeEditingPhase.ResultUnavailable ? Visibility.Visible : Visibility.Collapsed;
        _review.IsEnabled = !_running && session.CanReview;
        _stop.Visibility = session.Info is { StopRequested: false, State: not OfficeEditingState.Stopped } ? Visibility.Visible : Visibility.Collapsed;
    }
    internal static string PhaseKey(OfficeEditingPhase phase) => phase switch
    {
        OfficeEditingPhase.Preparing => "OfficePreparing", OfficeEditingPhase.Watching => "OfficeWatching",
        OfficeEditingPhase.WaitingForSave => "OfficeWaitingForSave", OfficeEditingPhase.Saving => "OfficeSaving",
        OfficeEditingPhase.Saved => "OfficeSaved", OfficeEditingPhase.Conflict => "OfficeConflict",
        OfficeEditingPhase.ResultUnavailable => "OfficeUnknown", OfficeEditingPhase.Stopped => "OfficeStopped", _ => "OfficePaused",
    };
    public void Dispose() { if (_disposed) return; _disposed = true; _coordinator.Changed -= Changed; }
}
