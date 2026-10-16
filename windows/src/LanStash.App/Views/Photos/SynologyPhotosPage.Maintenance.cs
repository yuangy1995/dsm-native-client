using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views.Photos;

public sealed partial class SynologyPhotosPage
{
    private async void PhotoMaintenance_Click(object sender, RoutedEventArgs args) => await ShowPhotoMaintenanceAsync(false);
    private async void PhotoCodecPrompt_Click(object sender, RoutedEventArgs args) => await ShowPhotoMaintenanceAsync(true);
    private async Task ShowPhotoMaintenanceAsync(bool codecMode)
    {
        if (_disposed || _dialog is not null) return;
        var generation = _viewGeneration; var space = _model.SelectedSpace; var closed = false; var busy = false; var confirming = false;
        var generate = true; var id = Guid.NewGuid(); var action = SynologyPhotoMaintenanceAction.Reindex;
        SynologyPhotoLibraryMaintenance? maintenance = null; SynologyPhotoCodecPrompt? codec = null; SynologyPhotoSettingsChange? operation = null;
        var fields = new StackPanel { Spacing = 12, MinWidth = 280, MaxWidth = 560 };
        var form = new ContentControl { Content = fields, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        var message = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var retry = new Button { Content = _l.Get("PhotosRefresh") }; AutomationProperties.SetAutomationId(retry, "PhotoMaintenanceRefresh");
        var back = new Button { Content = _l.Get("PhotosBack") }; AutomationProperties.SetAutomationId(back, "PhotoMaintenanceBack");
        var panel = new StackPanel { Spacing = 12 }; panel.Children.Add(form); panel.Children.Add(message); panel.Children.Add(back); panel.Children.Add(retry);
        var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = _l.Get(codecMode ? "PhotosCodecPrompt" : "PhotosLibraryMaintenance"),
            CloseButtonText = _l.Get("PhotosClose"), Content = new ScrollViewer { Content = panel, MaxHeight = 550, VerticalScrollBarVisibility = ScrollBarVisibility.Auto } };
        bool Current() => !closed && !_disposed && generation == _viewGeneration;
        bool Pending() => operation?.Pending == true;
        void Render()
        {
            if (!Current()) return;
            form.IsEnabled = !busy && !Pending(); form.Visibility = Visible(!confirming);
            dialog.PrimaryButtonText = confirming ? _l.Get(codecMode ? "PhotosCodecGenerate" : action == SynologyPhotoMaintenanceAction.Reindex ? "PhotosLibraryReindex" : "PhotosLibraryPreviews") : "";
            dialog.IsPrimaryButtonEnabled = confirming && !busy && !Pending();
            back.Visibility = Visible(confirming && !busy); retry.Visibility = Visible(!confirming); retry.IsEnabled = !busy;
            message.Visibility = Visible(message.Text.Length > 0);
        }
        string ResultText(SynologyPhotoSettingsChange result)
        {
            if (result.Maintenance is { } change)
            {
                var source = _l.Get(change.Original.Space == SynologyPhotoSpace.Personal ? "PhotosSourcePersonal" : "PhotosSourceShared");
                return _l.Format("PhotosLibraryResult", source, _l.Get(result.State == SynologyPhotoChangeState.Completed ? "PhotosLibraryStageFinished" : result.Pending ?
                    result.MaintenanceAccepted ? "PhotosLibraryProcessing" : "PhotosLibraryUnreachable" : "PhotosLibraryFailed"));
            }
            if (result.Codec is not null) return _l.Get(result.Pending ? "PhotosLibraryUnreachable" : result.CodecGenerationAccepted ?
                result.State == SynologyPhotoChangeState.Completed ? "PhotosCodecStarted" : "PhotosCodecPartial" : result.State == SynologyPhotoChangeState.Completed ? "PhotosCodecDismissed" : "PhotosLibraryFailed");
            return _l.Get("PhotosPreferenceSaving");
        }
        void Text(string value) => fields.Children.Add(new TextBlock { Text = value, TextWrapping = TextWrapping.Wrap });
        Button ActionButton(string key, string automationId, bool enabled, Action click)
        {
            var button = new Button { Content = _l.Get(key), IsEnabled = enabled, HorizontalAlignment = HorizontalAlignment.Stretch };
            AutomationProperties.SetAutomationId(button, automationId); button.Click += (_, _) => { if (!busy && !Pending()) click(); }; fields.Children.Add(button); return button;
        }
        void Populate()
        {
            fields.Children.Clear();
            if (codecMode && codec is { } prompt)
            {
                Text(_l.Get(!prompt.ShouldShow ? "PhotosCodecEmpty" : prompt.GenerationAlreadySubmitted ? "PhotosCodecPartial" : !prompt.CanGenerate ? "PhotosCodecNoLibrary" : prompt.IsAdministrator ? "PhotosCodecAllUsers" : "PhotosCodecPersonal"));
                if (!prompt.ShouldShow) return;
                if (!prompt.GenerationAlreadySubmitted)
                    ActionButton("PhotosCodecGenerate", "PhotoCodecGenerate", prompt.CanGenerate, () =>
                    { generate = true; confirming = true; message.Text = _l.Get(prompt.IsAdministrator ? "PhotosCodecAllWarning" : "PhotosCodecPersonalWarning"); Render(); });
                var later = ActionButton(prompt.GenerationAlreadySubmitted ? "PhotosCodecFinishPrompt" : "PhotosCodecLater", "PhotoCodecLater", true, () => { });
                later.Click += async (_, _) => { if (!busy && !Pending()) { generate = false; await Submit(); } };
            }
            else if (!codecMode && maintenance is { } status)
            {
                Text(_l.Get(status.Space == SynologyPhotoSpace.Personal ? "PhotosSourcePersonal" : "PhotosSourceShared"));
                Text(_l.Format("PhotosLibraryCounts", status.IndexingCount, status.PreviewCount));
                ActionButton("PhotosLibraryReindex", "PhotoLibraryReindex", status.CanStart(SynologyPhotoMaintenanceAction.Reindex), () => Confirm(SynologyPhotoMaintenanceAction.Reindex));
                ActionButton("PhotosLibraryPreviews", "PhotoLibraryPreviews", status.CanStart(SynologyPhotoMaintenanceAction.Previews), () => Confirm(SynologyPhotoMaintenanceAction.Previews));
                if (!status.SupportsPreviews) Text(_l.Get("PhotosLibraryPreviewUnavailable"));
            }
        }
        void Confirm(SynologyPhotoMaintenanceAction selected)
        { action = selected; confirming = true; message.Text = _l.Get(selected == SynologyPhotoMaintenanceAction.Reindex ? "PhotosLibraryReindexWarning" : "PhotosLibraryPreviewWarning"); Render(); }
        async Task Load()
        {
            if (!Current() || busy || confirming) return; busy = true; message.Text = _l.Get("PhotosLoadingDescription"); Render();
            try
            {
                var pending = (await _model.Repository.SettingsChangesAsync(_viewCancellation.Token)).SingleOrDefault(value => value.Pending);
                if (pending is not null)
                {
                    operation = await _model.Repository.ReviewSettingsChangeAsync(pending.Id, _viewCancellation.Token); if (!Current()) return;
                    await _model.ApplySettingsChangeAsync(operation); if (!Current()) { if (ReferenceEquals(_dialog, dialog)) dialog.Hide(); return; }
                    if (operation.Pending && (codecMode ? operation.Codec is null : operation.Maintenance?.Original.Space != space))
                    { fields.Children.Clear(); message.Text = ResultText(operation); return; }
                }
                if (codecMode) codec = await _model.Repository.CodecPromptAsync(_viewCancellation.Token);
                else maintenance = await _model.Repository.LibraryMaintenanceAsync(space, _viewCancellation.Token);
                if (!Current()) return; Populate(); id = Guid.NewGuid(); message.Text = operation is null || codecMode && codec?.GenerationAlreadySubmitted == true && operation.PartiallySaved ? "" : ResultText(operation);
            }
            catch (Exception error) { if (Current()) { maintenance = null; codec = null; fields.Children.Clear(); message.Text = _l.Get(PreferenceErrorKey(error)); } }
            finally { busy = false; Render(); }
        }
        async Task Submit()
        {
            if (!Current() || busy || Pending() || (codecMode ? codec is null : maintenance is null)) return;
            busy = true; message.Text = _l.Get("PhotosPreferenceSaving"); Render();
            try
            {
                // 关闭弹窗只结束前台刷新；已提交的任务继续归属于原账号。
                operation = codecMode ? await _model.Repository.RespondToCodecPromptAsync(id, codec!, generate, generate) :
                    await _model.Repository.MaintainLibraryAsync(id, maintenance!, action, true);
                if (!Current()) return; confirming = false; maintenance = null; codec = null; fields.Children.Clear(); message.Text = ResultText(operation);
            }
            catch (Exception error) { if (Current()) { confirming = false; maintenance = null; codec = null; fields.Children.Clear(); message.Text = _l.Get(PreferenceErrorKey(error)); } }
            finally { busy = false; Render(); }
            if (Current() && !Pending()) await Load();
        }
        back.Click += (_, _) => { confirming = false; message.Text = operation is null ? "" : ResultText(operation); Render(); };
        retry.Click += async (_, _) => await Load();
        dialog.PrimaryButtonClick += async (_, args) => { args.Cancel = true; if (!confirming) return; var deferral = args.GetDeferral(); try { await Submit(); } finally { deferral.Complete(); } };
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(15) };
        timer.Tick += async (_, _) => { if (!busy && !confirming && (Pending() || maintenance is { IndexingCount: > 0 } or { PreviewCount: > 0 })) await Load(); };
        dialog.Closed += (_, _) => closed = true;
        try
        {
            if (MoreButton.Flyout.IsOpen) MoreButton.Flyout.Hide(); SetPhotoDialog(dialog); await _model.Automatic.YieldAsync();
            var showing = ShowPhotoDialogAsync(dialog); timer.Start(); await Load(); await showing;
        }
        finally { closed = true; timer.Stop(); if (ReferenceEquals(_dialog, dialog)) SetPhotoDialog(null); RenderPreviewControls(); }
    }
}
