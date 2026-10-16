using LanStash.App.Features.Chat;
using LanStash.App.Localization;
using LanStash.App.Features.Transfers;
using LanStash.App.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

internal sealed class ChatSavedRecordingsDialog : ContentDialog
{
    private readonly IChatSavedRecordings _store;
    private readonly Func<IReadOnlySet<string>> _protectedPaths;
    private readonly Func<string, Task<string?>> _chooseDestination;
    private readonly LocalizationService _l = LocalizationService.Current;
    private readonly StackPanel _items = new() { Spacing = 12 };
    private readonly TextBlock _empty = new() { TextWrapping = TextWrapping.Wrap };
    private readonly ProgressRing _loading = new() { Width = 32, Height = 32, Visibility = Visibility.Collapsed };
    private readonly InfoBar _status = new() { IsClosable = false };
    private readonly Button _refresh;
    private readonly TextBox _search;
    private readonly StackPanel _confirmation = new() { Spacing = 8, Visibility = Visibility.Collapsed };
    private readonly TextBlock _confirmText = new() { TextWrapping = TextWrapping.Wrap };
    private IReadOnlyList<ChatSavedRecording> _recordings = [];
    private ChatSavedRecording? _discardTarget;
    private bool _busy, _closed;
    internal Task LoadingTask { get; private set; } = Task.CompletedTask;
    private static bool _showing;

    internal static async Task ShowForAsync(AppViewModel app, FrameworkElement owner)
    {
        if (_showing) return;
        _showing = true;
        try
        {
            var picker = new WindowsTransferSavePicker(() => (Application.Current as App)?.MainWindow);
            var dialog = new ChatSavedRecordingsDialog(app.SavedVoiceRecordings, app.ProtectedVoicePaths, picker.PickSavePathAsync)
                { XamlRoot = owner.XamlRoot, RequestedTheme = owner.ActualTheme };
            await dialog.ShowAsync();
        }
        catch (InvalidOperationException) { /* 另一模态窗口仍在显示时保留当前窗口。 */ }
        finally { _showing = false; }
    }

    internal ChatSavedRecordingsDialog(IChatSavedRecordings store, Func<IReadOnlySet<string>> protectedPaths, Func<string, Task<string?>> chooseDestination)
    {
        _store = store; _protectedPaths = protectedPaths; _chooseDestination = chooseDestination;
        Title = _l.Get("ChatSavedRecordingsTitle"); CloseButtonText = _l.Get("ActionClose"); DefaultButton = ContentDialogButton.Close;
        AutomationProperties.SetAutomationId(this, "ChatSavedRecordingsDialog");
        _search = new() { PlaceholderText = _l.Get("ChatSavedRecordingsSearch"), MinHeight = 44 };
        AutomationProperties.SetName(_search, _l.Get("ChatSavedRecordingsSearch")); AutomationProperties.SetAutomationId(_search, "ChatSavedRecordingsSearch");
        _search.TextChanged += (_, _) => Render();
        _refresh = Button("ChatSavedRecordingsRefresh", async () => await RefreshAsync());
        var body = new StackPanel { Spacing = 12, MinWidth = 400, MaxWidth = 640 };
        body.Children.Add(new TextBlock { Text = _l.Get("ChatSavedRecordingsDescription"), TextWrapping = TextWrapping.Wrap });
        body.Children.Add(_search); body.Children.Add(_refresh); body.Children.Add(_loading); body.Children.Add(_empty); body.Children.Add(_items);
        _confirmation.Children.Add(_confirmText);
        AutomationProperties.SetAutomationId(_confirmation, "ChatSavedRecordingsDiscardConfirmation");
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        actions.Children.Add(Button("ChatSavedRecordingsDiscardConfirm", DiscardAsync));
        actions.Children.Add(Button("ActionCancel", () => { _discardTarget = null; _confirmation.Visibility = Visibility.Collapsed; return Task.CompletedTask; }));
        _confirmation.Children.Add(actions); body.Children.Add(_confirmation); body.Children.Add(_status);
        Content = new ScrollViewer { Content = body, MaxHeight = 560, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        AutomationProperties.SetLiveSetting(_status, AutomationLiveSetting.Polite);
        AutomationProperties.SetAutomationId(_empty, "ChatSavedRecordingsEmpty"); AutomationProperties.SetAutomationId(_status, "ChatSavedRecordingsStatus");
        Opened += (_, _) => LoadingTask = RefreshAsync();
        Closing += (_, args) => { if (_busy) args.Cancel = true; };
        Closed += (_, _) => _closed = true;
    }

    internal async Task RefreshAsync()
    {
        if (_busy || _closed) return;
        SetBusy(true); _status.IsOpen = false; _discardTarget = null; _confirmation.Visibility = Visibility.Collapsed;
        try
        {
            var result = await _store.ListAsync(_protectedPaths());
            _recordings = result.Items;
            if (result.UnavailableCount > 0) ShowStatus("ChatSavedRecordingsSomeUnavailable", InfoBarSeverity.Warning);
        }
        catch { _recordings = []; ShowStatus("ChatSavedRecordingsReadFailed", InfoBarSeverity.Error); }
        finally { SetBusy(false); Render(); }
    }

    private void Render()
    {
        if (_closed) return;
        _items.Children.Clear();
        foreach (var recording in _recordings.Where(item => TitleFor(item).Contains(_search.Text.Trim(), StringComparison.CurrentCultureIgnoreCase)))
        {
            var row = new StackPanel { Spacing = 8 };
            row.Children.Add(new TextBlock { Text = TitleFor(recording), TextWrapping = TextWrapping.Wrap });
            row.Children.Add(new TextBlock { Text = _l.Format("ChatSavedRecordingsSize", recording.Length), TextWrapping = TextWrapping.Wrap });
            var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            var export = Button("ChatSavedRecordingsExport", () => ExportAsync(recording)); export.Tag = recording;
            var discard = Button("ChatSavedRecordingsDiscard", () =>
            {
                if (!_busy) { _discardTarget = recording; _confirmText.Text = _l.Format("ChatSavedRecordingsDiscardMessage", TitleFor(recording)); _confirmation.Visibility = Visibility.Visible; }
                return Task.CompletedTask;
            }); discard.Tag = recording;
            buttons.Children.Add(export); buttons.Children.Add(discard); row.Children.Add(buttons); _items.Children.Add(row);
        }
        _empty.Text = _l.Get(_recordings.Count == 0 ? "ChatSavedRecordingsEmpty" : "ChatSavedRecordingsFilteredEmpty");
        _empty.Visibility = !_busy && _items.Children.Count == 0 && !(_status.IsOpen && _status.Severity == InfoBarSeverity.Error) ? Visibility.Visible : Visibility.Collapsed;
    }

    private async Task ExportAsync(ChatSavedRecording recording)
    {
        if (_busy) return;
        SetBusy(true); _status.IsOpen = false;
        try
        {
            var destination = await _chooseDestination("recording.m4a");
            if (destination is null) return;
            await _store.ExportAsync(recording, destination, _protectedPaths());
            ShowStatus("ChatSavedRecordingsExported", InfoBarSeverity.Success);
        }
        catch { ShowStatus("ChatSavedRecordingsExportFailed", InfoBarSeverity.Error); }
        finally { SetBusy(false); }
    }

    private Task DiscardAsync()
    {
        if (_busy || _discardTarget is not { } recording) return Task.CompletedTask;
        SetBusy(true); _status.IsOpen = false;
        try
        {
            _store.Discard(recording, _protectedPaths());
            _recordings = _recordings.Where(item => item != recording).ToArray();
            _discardTarget = null; _confirmation.Visibility = Visibility.Collapsed;
            ShowStatus("ChatSavedRecordingsDiscarded", InfoBarSeverity.Success);
        }
        catch { ShowStatus("ChatSavedRecordingsDiscardFailed", InfoBarSeverity.Error); }
        finally { SetBusy(false); Render(); }
        return Task.CompletedTask;
    }

    private string TitleFor(ChatSavedRecording recording) => _l.Format("ChatSavedRecordingsItem", recording.Created.ToLocalTime());
    private Button Button(string key, Func<Task> action)
    {
        var button = new Button { Content = _l.Get(key), MinHeight = 44 };
        AutomationProperties.SetAutomationId(button, key); button.Click += async (_, _) => await action(); return button;
    }
    private void SetBusy(bool busy)
    {
        _busy = busy; _items.IsHitTestVisible = !busy; _confirmation.IsHitTestVisible = !busy;
        _refresh.IsEnabled = !busy; _search.IsEnabled = !busy;
        _loading.IsActive = busy; _loading.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
        if (busy) _empty.Visibility = Visibility.Collapsed;
    }
    private void ShowStatus(string key, InfoBarSeverity severity) { _status.Message = _l.Get(key); _status.Severity = severity; _status.IsOpen = true; }
}
