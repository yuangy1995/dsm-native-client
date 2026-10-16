using System.Text.Json;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views.Photos;

public sealed partial class SynologyPhotosPage
{
    private async void CreateConditionAlbum_Click(object sender, RoutedEventArgs args) => await ShowConditionAlbumAsync(SynologyPhotoAlbumEditKind.CreateCondition);
    private async void EditConditionAlbum_Click(object sender, RoutedEventArgs args) => await ShowConditionAlbumAsync(SynologyPhotoAlbumEditKind.Condition, SelectedAlbumId());
    private async void UnfreezeAlbum_Click(object sender, RoutedEventArgs args) => await ShowConditionAlbumAsync(SynologyPhotoAlbumEditKind.Unfreeze, SelectedAlbumId());
    private async void RebuildAlbum_Click(object sender, RoutedEventArgs args) => await ShowConditionAlbumAsync(SynologyPhotoAlbumEditKind.Rebuild, SelectedAlbumId());
    private string FrozenConditionTitle(string key) => _l.Get(key switch
    {
        "recently_add" => "PhotosCategoryRecent", "recently_comment" => "PhotosConditionComments", "update_time" => "PhotosConditionModified",
        "people" or "person" => "PhotosCategoryPeople", "geocoding" => "PhotosFilterLocation", "rating" => "PhotosFilterRating",
        "camera" => "PhotosFilterCamera", "lens" => "PhotosFilterLens", "flash" => "PhotosConditionFlash", _ => "PhotosConditionUnknownRule",
    });
    private async Task ShowConditionAlbumAsync(SynologyPhotoAlbumEditKind kind, long? albumId = null, SynologyPhotoAlbumChange? resume = null)
    {
        if (_disposed || _dialog is not null || _managementPreparing || !_model.Repository.SupportsAlbumManagement) return;
        _managementPreparing = true; RenderManagementControls();
        var generation = _viewGeneration; var closed = false; var busy = false; var submitting = false; var ready = false; var previewing = false;
        var edit = resume?.Edit ?? new(kind); var id = resume?.Id ?? Guid.NewGuid(); var cleanup = resume?.ReplacementCreated == true;
        var needsName = !cleanup && kind is SynologyPhotoAlbumEditKind.CreateCondition or SynologyPhotoAlbumEditKind.Rebuild;
        var needsCondition = !cleanup && kind != SynologyPhotoAlbumEditKind.Unfreeze;
        SynologyPhotoAlbumChange? submitted = null; SynologyPhotoConditionEditor? editor = null;
        var name = new TextBox { Header = _l.Get("PhotosAlbumName"), Text = edit.Name ?? "", MaxLength = 255, Visibility = Visible(needsName) };
        var target = new TextBlock { TextWrapping = TextWrapping.Wrap }; var risk = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var unsupported = new TextBlock { TextWrapping = TextWrapping.Wrap }; var message = new TextBlock { TextWrapping = TextWrapping.Wrap }; var count = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var host = new ContentControl { HorizontalContentAlignment = HorizontalAlignment.Stretch };
        var retry = QueueButton("PhotosRetry"); var preview = QueueButton("PhotosConditionPreview"); var progress = new ProgressRing { Width = 24, Height = 24, HorizontalAlignment = HorizontalAlignment.Left };
        var panel = new StackPanel { MinWidth = 290, MaxWidth = 580, Spacing = 12 };
        foreach (var child in new FrameworkElement[] { target, name, risk, unsupported, progress, host, preview, count, message, retry }) panel.Children.Add(child);
        var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = AlbumEditTitle(kind),
            PrimaryButtonText = cleanup ? _l.Get("PhotosAlbumContinue") : AlbumEditTitle(kind), CloseButtonText = _l.Get("PhotosCancel"),
            DefaultButton = ContentDialogButton.Close, IsPrimaryButtonEnabled = false, Content = new ScrollViewer { Content = panel, MaxHeight = 550, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled } };
        bool Current() => !closed && !_disposed && generation == _viewGeneration;
        void Render()
        {
            if (!Current()) return; var waiting = busy || previewing || editor?.Busy == true;
            name.IsEnabled = !waiting && (resume is null || resume.Edit.Name is null); host.IsEnabled = !busy && !previewing && (resume is null || resume.Edit.Condition is null);
            preview.Visibility = Visible(needsCondition && ready); preview.IsEnabled = !waiting && editor?.Valid == true;
            dialog.IsPrimaryButtonEnabled = !waiting && ready && (!needsName || !string.IsNullOrWhiteSpace(name.Text)) && (!needsCondition || editor?.Valid == true);
            retry.Visibility = Visible(!ready); retry.IsEnabled = !waiting; progress.IsActive = waiting; progress.Visibility = Visible(waiting);
            if (editor is { Valid: false }) message.Text = _l.Get("PhotosFilterInvalidDate");
            foreach (var label in new[] { target, risk, unsupported, message, count }) label.Visibility = Visible(label.Text.Length > 0);
        }
        SynologyPhotoAlbumEdit Input() => edit with { Name = needsName ? name.Text : null, Condition = needsCondition ? editor!.Build() : null };
        async Task Load()
        {
            if (!Current() || busy) return; busy = true; ready = false; message.Text = _l.Get("PhotosLoadingDescription"); Render();
            try
            {
                var condition = edit.Condition;
                if (!cleanup && kind == SynologyPhotoAlbumEditKind.Condition)
                {
                    var snapshot = await _model.Repository.AlbumConditionAsync(edit.Album?.Id ?? albumId!.Value, _viewCancellation.Token);
                    if (!Current()) return;
                    if (resume is null) edit = edit with { Album = snapshot.Album, OriginalConditionRevision = snapshot.Revision };
                    condition ??= snapshot.Condition;
                }
                else if (!cleanup && kind is SynologyPhotoAlbumEditKind.Unfreeze or SynologyPhotoAlbumEditKind.Rebuild)
                {
                    var frozen = await _model.Repository.FrozenAlbumAsync(edit.Album?.Id ?? albumId!.Value, _viewCancellation.Token);
                    if (!Current()) return; if (resume is null) edit = edit with { Album = frozen.Album };
                    if (kind == SynologyPhotoAlbumEditKind.Rebuild && !frozen.CanRebuild) throw new PhotoEditInputException("PhotosConditionCannotRebuild");
                    condition ??= frozen.RebuildCondition;
                    unsupported.Text = frozen.UnsupportedConditions.Count == 0 ? "" : _l.Format("PhotosConditionUnsupported", frozen.UnsupportedConditions.Count,
                        string.Join(_l.Get("PhotosConditionListSeparator"), frozen.UnsupportedConditions.Select(FrozenConditionTitle).Distinct()));
                    if (needsName && resume is null) name.Text = frozen.Album.Name;
                }
                target.Text = edit.Album?.Name ?? ""; target.Visibility = Visible(target.Text.Length > 0);
                if (needsCondition)
                {
                    if (condition is null && _model.ConditionSpaces.Count == 0) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
                    condition ??= new SynologyPhotoCondition(edit.ConditionSpace ?? (_model.ConditionSpaces.Contains(_model.SelectedSpace) ? _model.SelectedSpace : _model.ConditionSpaces[0]), new Dictionary<string, JsonElement> { ["item_type"] = JsonSerializer.SerializeToElement(Array.Empty<int>()) });
                    editor = new(_model.Repository, condition, _model.ConditionSpaces, Current, error => _l.Get(AlbumErrorKey(error)), _viewCancellation.Token);
                    editor.Changed += () => { if (Current()) { count.Text = ""; message.Text = ""; Render(); } }; host.Content = editor;
                }
                risk.Text = cleanup ? _l.Get("PhotosConditionCleanupRisk") : kind == SynologyPhotoAlbumEditKind.Unfreeze ? _l.Get("PhotosUnfreezeRisk") :
                    kind == SynologyPhotoAlbumEditKind.Rebuild ? _l.Get("PhotosRebuildRisk") : "";
                if (resume is not null && !cleanup && (needsCondition && resume.Edit.Condition is null || needsName && resume.Edit.Name is null))
                    risk.Text = string.Join(Environment.NewLine, new[] { risk.Text, _l.Get("PhotosConditionReenter") }.Where(value => value.Length > 0));
                ready = true; message.Text = "";
            }
            catch (Exception error) { if (Current()) message.Text = _l.Get(AlbumErrorKey(error)); }
            finally { busy = false; Render(); }
        }
        preview.Click += async (_, _) =>
        {
            if (!Current() || editor is not { Valid: true } || !preview.IsEnabled) return;
            previewing = true; var version = editor.EditVersion; count.Text = ""; Render();
            try { var value = await _model.Repository.ConditionItemCountAsync(editor.Build(), _viewCancellation.Token); if (Current() && version == editor.EditVersion) count.Text = _l.Format("PhotosConditionCount", value); }
            catch (Exception error) { if (Current()) message.Text = _l.Get(AlbumErrorKey(error)); }
            finally { previewing = false; Render(); }
        };
        name.TextChanged += (_, _) => Render(); retry.Click += async (_, _) => await Load();
        dialog.Closing += (_, args) => { if (submitting && Current() && _windowVisible && IsLoaded) args.Cancel = true; }; dialog.Closed += (_, _) => closed = true;
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true; if (!Current() || !dialog.IsPrimaryButtonEnabled) return; var deferral = args.GetDeferral(); busy = submitting = true; Render();
            try
            {
                submitted = cleanup ? await _model.Repository.ContinueAlbumChangeAsync(id) : await _model.Repository.EditAlbumAsync(id, Input());
                if (resume is not null && !cleanup && submitted.CanContinue) submitted = await _model.Repository.ContinueAlbumChangeAsync(id);
                if (Current()) args.Cancel = false;
            }
            catch (Exception error) { if (Current()) message.Text = _l.Get(resume is not null && needsCondition && error is SynologyPhotoException { Failure: SynologyPhotoFailure.TargetChanged } ? "PhotosConditionIntentMismatch" : AlbumErrorKey(error)); }
            finally { busy = submitting = false; Render(); deferral.Complete(); }
        };
        try { SetPhotoDialog(dialog); await _model.Automatic.YieldAsync(); Render(); var showing = ShowPhotoDialogAsync(dialog); await Load(); await showing; }
        finally { closed = true; _managementPreparing = false; if (ReferenceEquals(_dialog, dialog)) SetPhotoDialog(null); RenderManagementControls(); }
        if (submitted is not null && !_disposed && generation == _viewGeneration)
        {
            if (submitted.Pending) _pendingAlbumChanges.Add(submitted.Id); await _model.ApplyAlbumChangeAsync(submitted);
            if (!_disposed && _windowVisible) await ShowAlbumChangesAsync(submitted.Id);
        }
    }
}
