using System.Globalization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views.Photos;

public sealed partial class SynologyPhotosPage
{
    private async void PhotoBackgroundTasks_Click(object sender, RoutedEventArgs args) => await ShowPhotoBackgroundTasksAsync();
    private async Task ShowPhotoBackgroundTasksAsync()
    {
        if (_disposed || _dialog is not null) return;
        var generation = _viewGeneration; var closed = false; var busy = false; var loaded = false; var detailRequest = 0;
        using var reads = CancellationTokenSource.CreateLinkedTokenSource(_viewCancellation.Token);
        IReadOnlyList<SynologyPhotoBackgroundTask> tasks = []; IReadOnlyList<SynologyPhotoSettingsChange> operations = [];
        var selected = new Dictionary<long, SynologyPhotoBackgroundTask>(); SynologyPhotoBackgroundTask? detail = null;
        SynologyPhotoBackgroundCommand? confirmation = null; SynologyPhotoSettingsChange? result = null;
        var fields = new StackPanel { Spacing = 12, MinWidth = 280, MaxWidth = 560 };
        var status = new TextBlock { TextWrapping = TextWrapping.Wrap }; AutomationProperties.SetAutomationId(status, "PhotoTaskStatus");
        var form = new ContentControl { Content = fields, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        var filter = new ComboBox { Header = _l.Get("PhotosTaskFilter"), HorizontalAlignment = HorizontalAlignment.Stretch };
        foreach (var key in new[] { "PhotosTaskAll", "PhotosTaskActive", "PhotosTaskFinished" }) filter.Items.Add(_l.Get(key));
        filter.SelectedIndex = 0; AutomationProperties.SetAutomationId(filter, "PhotoTaskFilter");
        var refresh = new Button { Content = _l.Get("PhotosRefresh") }; AutomationProperties.SetAutomationId(refresh, "PhotoTaskRefresh");
        var back = new Button { Content = _l.Get("PhotosBack") }; AutomationProperties.SetAutomationId(back, "PhotoTaskBack");
        var clear = new Button { Content = _l.Get("PhotosTaskClearSelected") }; AutomationProperties.SetAutomationId(clear, "PhotoTaskClearSelected");
        var panel = new StackPanel { Spacing = 12 }; panel.Children.Add(filter); panel.Children.Add(form); panel.Children.Add(status); panel.Children.Add(clear); panel.Children.Add(back); panel.Children.Add(refresh);
        var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = _l.Get("PhotosBackgroundTasks"), CloseButtonText = _l.Get("PhotosClose"),
            Content = new ScrollViewer { Content = panel, MaxHeight = 550, VerticalScrollBarVisibility = ScrollBarVisibility.Auto } };
        bool Current() => !closed && !_disposed && generation == _viewGeneration;
        bool Pending(SynologyPhotoBackgroundTask target) => operations.Any(value => value.Pending && value.Background?.Targets.Any(item => item.Id == target.Id) == true);
        string Title(SynologyPhotoBackgroundTask task) => _l.Get(task.Operation switch { "copy" => "PhotosTaskCopy", "move" => "PhotosTaskMove", _ => "PhotosTaskOther" });
        string State(SynologyPhotoBackgroundTask task) => _l.Get(task.Status switch
        { SynologyPhotoBackgroundStatus.Waiting => "PhotosTaskWaiting", SynologyPhotoBackgroundStatus.Processing => "PhotosTaskProcessing", SynologyPhotoBackgroundStatus.Aborting => "PhotosTaskStopping",
            SynologyPhotoBackgroundStatus.Done => task.WasStopped ? "PhotosTaskStopped" : task.Errors > 0 ? "PhotosTaskWithErrors" : "PhotosTaskDone", _ => "PhotosTaskUnknown" });
        string Result(SynologyPhotoSettingsChange value) => value.Pending ? _l.Get("PhotosTaskResultPending") : value.State == SynologyPhotoChangeState.Completed ?
            _l.Get(value.Background?.Action == SynologyPhotoBackgroundAction.Stop ? "PhotosTaskStopComplete" : "PhotosTaskClearComplete") :
            value.CompletedSteps > 0 ? _l.Format("PhotosTaskPartial", value.CompletedSteps, value.TotalSteps) : _l.Get("PhotosTaskControlFailed");
        void Text(string value) => fields.Children.Add(new TextBlock { Text = value, TextWrapping = TextWrapping.Wrap });
        Button Button(string key, string id, bool enabled, Func<Task> click)
        {
            var button = new Button { Content = _l.Get(key), IsEnabled = enabled, HorizontalAlignment = HorizontalAlignment.Stretch };
            AutomationProperties.SetAutomationId(button, id); button.Click += async (_, _) => { if (!busy && Current()) await click(); }; fields.Children.Add(button); return button;
        }
        void RenderControls()
        {
            if (!Current()) return;
            form.IsEnabled = !busy; filter.IsEnabled = !busy; filter.Visibility = Visible(detail is null && confirmation is null);
            refresh.Visibility = Visible(confirmation is null); refresh.IsEnabled = !busy;
            clear.Visibility = Visible(detail is null && confirmation is null && tasks.Any(task => task.CanClear));
            clear.IsEnabled = !busy && selected.Count > 0 && selected.Values.All(task => !Pending(task));
            back.Visibility = Visible(detail is not null || confirmation is not null); back.IsEnabled = !busy;
            dialog.PrimaryButtonText = confirmation is null ? "" : _l.Get(confirmation.Action == SynologyPhotoBackgroundAction.Stop ? "PhotosTaskStop" : "PhotosTaskClear");
            dialog.IsPrimaryButtonEnabled = confirmation is not null && !busy;
            status.Visibility = Visible(status.Text.Length > 0);
        }
        void Confirm(SynologyPhotoBackgroundAction action, IReadOnlyList<SynologyPhotoBackgroundTask> targets)
        {
            confirmation = new(action, targets.ToArray()); fields.Children.Clear();
            Text(action == SynologyPhotoBackgroundAction.Stop ? _l.Get("PhotosTaskStopWarning") : _l.Format("PhotosTaskClearWarning", targets.Count));
            status.Text = ""; RenderControls();
        }
        void Populate()
        {
            if (!Current() || confirmation is not null) return; fields.Children.Clear();
            if (detail is { } task)
            {
                Text(Title(task)); Text(State(task)); Text(_l.Format("PhotosTaskCounts", task.Completion, task.Total, task.SuccessfulCount, task.Errors, task.Skipped, task.Overwritten));
                try { Text(_l.Format("PhotosTaskCreated", DateTimeOffset.UnixEpoch.AddSeconds(task.CreatedAt).ToLocalTime().ToString("g", CultureInfo.CurrentCulture))); }
                catch (ArgumentOutOfRangeException) { /* 无法显示的时间不改变原始任务身份。 */ }
                if (!task.IsTransfer || task.Status == SynologyPhotoBackgroundStatus.Unknown) Text(_l.Get("PhotosTaskReadOnly"));
                if (task.TargetSpace is not null && task.TargetFolderId is not null)
                    Button("PhotosTaskOpenLocation", "PhotoTaskOpenLocation", true, async () =>
                    {
                        busy = true; status.Text = _l.Get("PhotosLoadingDescription"); RenderControls();
                        try { await _model.OpenBackgroundTaskLocationAsync(task, reads.Token); if (ReferenceEquals(_dialog, dialog)) dialog.Hide(); }
                        catch (Exception error) { if (Current()) status.Text = _l.Get(PreferenceErrorKey(error)); }
                        finally { busy = false; RenderControls(); }
                    });
                if (task.Errors > 0)
                    Button("PhotosTaskErrors", "PhotoTaskErrors", true, async () =>
                    {
                        busy = true; var request = ++detailRequest; status.Text = _l.Get("PhotosLoadingDescription"); RenderControls();
                        try
                        {
                            var errors = await _model.Repository.BackgroundTaskErrorsAsync(task, reads.Token);
                            if (!Current() || request != detailRequest || detail?.SameIdentity(task) != true) return;
                            Populate(); Text(_l.Get("PhotosTaskErrors"));
                            if (errors.Count == 0) Text(_l.Get("PhotosTaskErrorsEmpty"));
                            foreach (var error in errors)
                            {
                                Text(error.Name ?? _l.Get(error.Kind == SynologyPhotoBackgroundErrorKind.Item ? "PhotosTaskUnnamedPhoto" : error.Kind == SynologyPhotoBackgroundErrorKind.Folder ? "PhotosTaskUnnamedFolder" : "PhotosTaskUnnamedItem"));
                                if (!string.IsNullOrEmpty(error.FolderPath)) Text(error.FolderPath);
                                Text(_l.Get(error.Reason switch { SynologyPhotoBackgroundErrorReason.Quota => "PhotosTaskErrorQuota", SynologyPhotoBackgroundErrorReason.Space => "PhotosTaskErrorSpace",
                                    SynologyPhotoBackgroundErrorReason.Subfolder => "PhotosTaskErrorSubfolder", SynologyPhotoBackgroundErrorReason.Missing => "PhotosTaskErrorMissing",
                                    SynologyPhotoBackgroundErrorReason.TargetMissing => "PhotosTaskErrorTargetMissing", SynologyPhotoBackgroundErrorReason.Excluded => "PhotosTaskErrorExcluded", _ => "PhotosTaskErrorUnknown" }));
                            }
                            status.Text = "";
                        }
                        catch (Exception error) { if (Current()) status.Text = _l.Get(PreferenceErrorKey(error)); }
                        finally { busy = false; RenderControls(); }
                    });
                if (task.CanStop) Button("PhotosTaskStop", "PhotoTaskStop", !Pending(task), () => { Confirm(SynologyPhotoBackgroundAction.Stop, [task]); return Task.CompletedTask; });
                if (task.CanClear) Button("PhotosTaskClear", "PhotoTaskClear", !Pending(task), () => { Confirm(SynologyPhotoBackgroundAction.Clear, [task]); return Task.CompletedTask; });
                return;
            }
            var shown = tasks.Where(task => filter.SelectedIndex switch { 1 => task.Status is not SynologyPhotoBackgroundStatus.Done, 2 => task.Status == SynologyPhotoBackgroundStatus.Done, _ => true }).OrderByDescending(task => task.CreatedAt).ToArray();
            if (loaded && shown.Length == 0)
            {
                Text(_l.Get(tasks.Count == 0 ? "PhotosTasksEmpty" : "PhotosTasksFilteredEmpty"));
                if (tasks.Count > 0) Button("PhotosTaskShowAll", "PhotoTaskShowAll", true, () => { filter.SelectedIndex = 0; return Task.CompletedTask; });
            }
            foreach (var listed in shown)
            {
                var name = _l.Format("PhotosTaskRow", Title(listed), State(listed), listed.Completion, listed.Total);
                if (listed.CanClear)
                {
                    var check = new CheckBox { Content = new TextBlock { Text = name, TextWrapping = TextWrapping.Wrap }, IsChecked = selected.ContainsKey(listed.Id), IsEnabled = !Pending(listed) };
                    AutomationProperties.SetAutomationId(check, "PhotoTaskSelect" + listed.Id); AutomationProperties.SetName(check, name);
                    check.Checked += (_, _) => { selected[listed.Id] = listed; RenderControls(); }; check.Unchecked += (_, _) => { selected.Remove(listed.Id); RenderControls(); }; fields.Children.Add(check);
                }
                else Text(name);
                Button("PhotosTaskDetails", "PhotoTaskDetails" + listed.Id, true, () => { detail = listed; detailRequest++; Populate(); RenderControls(); return Task.CompletedTask; });
            }
            foreach (var pending in operations.Where(value => value.Pending)) Text(Result(pending));
        }
        async Task Load()
        {
            if (!Current() || busy || confirmation is not null) return; busy = true; status.Text = _l.Get("PhotosLoadingDescription"); RenderControls();
            try
            {
                var saved = await _model.Repository.BackgroundChangesAsync(reads.Token); var reviewed = new List<SynologyPhotoSettingsChange>();
                foreach (var item in saved) reviewed.Add(item.Pending ? await _model.Repository.ReviewSettingsChangeAsync(item.Id, reads.Token) : item);
                var values = await _model.Repository.BackgroundTasksAsync(reads.Token); if (!Current()) return;
                operations = reviewed; tasks = values; loaded = true;
                foreach (var id in selected.Keys.ToArray()) if (!tasks.Any(task => task.CanClear && task.SameIdentity(selected[id]))) selected.Remove(id);
                if (detail is { } original) detail = tasks.SingleOrDefault(task => task.SameIdentity(original));
                if (result is not null) result = reviewed.SingleOrDefault(value => value.Id == result.Id) ?? result;
                status.Text = result is null || result.Pending && detail is null ? "" : Result(result); Populate();
            }
            catch (Exception error) { if (Current()) { fields.Children.Clear(); tasks = []; selected.Clear(); status.Text = _l.Get(PreferenceErrorKey(error)); } }
            finally { busy = false; RenderControls(); }
        }
        async Task Submit()
        {
            if (!Current() || busy || confirmation is not { } command) return; busy = true; var failed = false; status.Text = _l.Get("PhotosPreferenceSaving"); RenderControls();
            try
            {
                // 表单结束只取消读取；已经发出的控制继续保存在原账号的恢复记录中。
                result = await _model.Repository.ControlBackgroundTasksAsync(Guid.NewGuid(), command, true);
                if (!Current()) return; confirmation = null; selected.Clear(); status.Text = Result(result);
            }
            catch (Exception error) { failed = true; if (Current()) { confirmation = null; Populate(); status.Text = _l.Get(PreferenceErrorKey(error)); } }
            finally { busy = false; RenderControls(); }
            if (Current() && !failed) await Load();
        }
        filter.SelectionChanged += (_, _) => { if (!busy) { Populate(); RenderControls(); } };
        back.Click += (_, _) => { if (confirmation is not null) confirmation = null; else { detail = null; detailRequest++; } Populate(); RenderControls(); };
        clear.Click += (_, _) => { if (!busy && selected.Count > 0) Confirm(SynologyPhotoBackgroundAction.Clear, selected.Values.ToArray()); };
        refresh.Click += async (_, _) => await Load();
        dialog.PrimaryButtonClick += async (_, args) => { args.Cancel = true; var deferral = args.GetDeferral(); try { await Submit(); } finally { deferral.Complete(); } };
        dialog.Closed += (_, _) => { closed = true; detailRequest++; reads.Cancel(); };
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(15) };
        timer.Tick += async (_, _) => { if (!busy && confirmation is null && (operations.Any(value => value.Pending) || tasks.Any(task => task.Status is SynologyPhotoBackgroundStatus.Waiting or SynologyPhotoBackgroundStatus.Processing or SynologyPhotoBackgroundStatus.Aborting))) await Load(); };
        try
        {
            if (MoreButton.Flyout.IsOpen) MoreButton.Flyout.Hide(); SetPhotoDialog(dialog); await _model.Automatic.YieldAsync();
            var showing = ShowPhotoDialogAsync(dialog); timer.Start(); await Load(); await showing;
        }
        finally { closed = true; reads.Cancel(); timer.Stop(); if (ReferenceEquals(_dialog, dialog)) SetPhotoDialog(null); RenderPreviewControls(); }
    }
}
