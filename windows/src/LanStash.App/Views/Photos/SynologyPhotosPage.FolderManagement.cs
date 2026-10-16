using LanStash.App.Features.Photos.Synology;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views.Photos;

public sealed partial class SynologyPhotosPage
{
    private sealed record PhotoFolderChangeChoice(Guid Id, string Title) { public override string ToString() => Title; }
    private SynologyPhotoCollection? SelectedPhotoFolder() => LibraryGrid.SelectedItems.Count == 1 && LibraryGrid.SelectedItems[0] is SynologyPhotoCell { Collection: { } folder }
        ? folder : LibraryGrid.SelectedItems.Count == 0 ? _model.FolderHistory.LastOrDefault() : null;
    private void RenderFolderControls()
    {
        var visible = _model.Repository.SupportsFolderManagement;
        CreatePhotoFolderMenu.Visibility = RenamePhotoFolderMenu.Visibility = SortPhotoFolderMenu.Visibility = CoverPhotoFolderMenu.Visibility = PhotoFolderChangesMenu.Visibility = Visible(visible);
        CreatePhotoFolderMenu.Text = _l.Get("PhotosCreateFolder"); RenamePhotoFolderMenu.Text = _l.Get("PhotosRenameFolder");
        SortPhotoFolderMenu.Text = _l.Get("PhotosSortFolder"); PhotoFolderChangesMenu.Text = _l.Get("PhotosFolderChanges");
        CoverPhotoFolderMenu.Text = _l.Get("PhotosSetFolderCover");
        var current = !_managementPreparing && !_model.IsLoading && _model.Section == SynologyPhotosSection.Folders && _model.FolderHistory.Count > 0 && !_model.IsFiltering;
        CreatePhotoFolderMenu.IsEnabled = current;
        RenamePhotoFolderMenu.IsEnabled = current && SelectedPhotoFolder() is { Path: not "/" } &&
            (LibraryGrid.SelectedItems.Count > 0 || _model.FolderHistory.Count > 1);
        SortPhotoFolderMenu.IsEnabled = current && LibraryGrid.SelectedItems.Count == 0;
        CoverPhotoFolderMenu.IsEnabled = RenamePhotoFolderMenu.IsEnabled;
    }
    private async void CreatePhotoFolder_Click(object sender, RoutedEventArgs args)
    { if (_model.FolderHistory.LastOrDefault() is { } folder) await ShowFolderEditAsync(SynologyPhotoFolderEditKind.Create, folder); }
    private async void RenamePhotoFolder_Click(object sender, RoutedEventArgs args)
    { if (SelectedPhotoFolder() is { } folder) await ShowFolderEditAsync(SynologyPhotoFolderEditKind.Rename, folder); }
    private async void SortPhotoFolder_Click(object sender, RoutedEventArgs args)
    { if (_model.FolderHistory.LastOrDefault() is { } folder) await ShowFolderEditAsync(SynologyPhotoFolderEditKind.Sort, folder); }
    private async void PhotoFolderChanges_Click(object sender, RoutedEventArgs args) => await ShowFolderChangesAsync();
    private async void CoverPhotoFolder_Click(object sender, RoutedEventArgs args)
    { if (SelectedPhotoFolder() is { } folder) await ShowFolderCoverAsync(folder); }
    private string FolderEditTitle(SynologyPhotoFolderEditKind kind) => _l.Get(kind switch
    { SynologyPhotoFolderEditKind.Create => "PhotosCreateFolder", SynologyPhotoFolderEditKind.Rename => "PhotosRenameFolder", SynologyPhotoFolderEditKind.Cover => "PhotosSetFolderCover", _ => "PhotosSortFolder" });
    private string PhotoSortTitle(SynologyPhotoSortField field) => _l.Get(field switch
    { SynologyPhotoSortField.Filename => "PhotosSortFilename", SynologyPhotoSortField.FileSize => "PhotosSortSize",
      SynologyPhotoSortField.MediaType => "PhotosSortType", _ => "PhotosSortDate" });
    private async Task ShowFolderEditAsync(SynologyPhotoFolderEditKind kind, SynologyPhotoCollection target)
    {
        if (_disposed || _dialog is not null || _managementPreparing) return;
        var generation = _viewGeneration; var closed = false; _managementPreparing = true; RenderManagementControls();
        SynologyPhotoFolder? original = null; SynologyPhotoFolderChange? submitted = null;
        var name = new TextBox { Header = _l.Get("PhotosFolderName"), MaxLength = 255 };
        var field = new ComboBox { Header = _l.Get("PhotosSortBy"), ItemsSource = Enum.GetValues<SynologyPhotoSortField>().Select(PhotoSortTitle).ToArray(), HorizontalAlignment = HorizontalAlignment.Stretch };
        var direction = new ComboBox { Header = _l.Get("PhotosSortDirection"), ItemsSource = new[] { _l.Get("PhotosSortAscending"), _l.Get("PhotosSortDescending") }, HorizontalAlignment = HorizontalAlignment.Stretch };
        var message = new TextBlock { Text = _l.Get("PhotosLoadingDescription"), TextWrapping = TextWrapping.Wrap };
        var progress = new ProgressRing { IsActive = true, Width = 24, Height = 24, HorizontalAlignment = HorizontalAlignment.Left };
        var fields = new StackPanel { Spacing = 12, Visibility = Visibility.Collapsed }; fields.Children.Add(name); fields.Children.Add(field); fields.Children.Add(direction);
        var content = new StackPanel { Spacing = 12, MinWidth = 290, MaxWidth = 560 }; content.Children.Add(progress); content.Children.Add(message); content.Children.Add(fields);
        var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = FolderEditTitle(kind),
            PrimaryButtonText = kind == SynologyPhotoFolderEditKind.Create ? _l.Get("PhotosCreateFolder") : _l.Get("PhotosSaveChanges"), CloseButtonText = _l.Get("PhotosCancel"),
            IsPrimaryButtonEnabled = false, Content = new ScrollViewer { Content = content, MaxHeight = 530 } };
        bool Current() => !closed && !_disposed && generation == _viewGeneration;
        dialog.Closed += (_, _) => closed = true;
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true; if (original is null || !Current()) return;
            var deferral = args.GetDeferral(); dialog.IsPrimaryButtonEnabled = false;
            foreach (var control in fields.Children.OfType<Control>()) control.IsEnabled = false;
            progress.IsActive = true; progress.Visibility = Visibility.Visible;
            try
            {
                var edit = new SynologyPhotoFolderEdit(kind, original) { Name = kind == SynologyPhotoFolderEditKind.Sort ? null : name.Text,
                    Sort = kind == SynologyPhotoFolderEditKind.Sort ? new((SynologyPhotoSortField)field.SelectedIndex, direction.SelectedIndex == 1) : null };
                if (kind != SynologyPhotoFolderEditKind.Sort && !SynologyPhotoFolderEdit.IsValidName(name.Text, kind == SynologyPhotoFolderEditKind.Rename)) throw new PhotoEditInputException("PhotosFolderNameInvalid");
                submitted = await _model.Repository.EditFolderAsync(Guid.NewGuid(), edit);
                if (Current()) args.Cancel = false;
            }
            catch (Exception error) { if (Current()) { message.Text = _l.Get(ManagementErrorKey(error)); message.Visibility = Visibility.Visible; } }
            finally
            {
                if (Current()) { dialog.IsPrimaryButtonEnabled = true; progress.IsActive = false; progress.Visibility = Visibility.Collapsed; foreach (var control in fields.Children.OfType<Control>()) control.IsEnabled = true; }
                deferral.Complete();
            }
        };
        try
        {
            SetPhotoDialog(dialog); await _model.Automatic.YieldAsync(); var showing = ShowPhotoDialogAsync(dialog);
            try
            {
                original = await _model.Repository.FolderAsync(target.Id, target.Space, _viewCancellation.Token);
                if (target.Path is { } expected && original.Path != expected || target.ParentId is { } parent && original.ParentId != parent)
                    throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
                if (Current())
                {
                    name.Text = kind == SynologyPhotoFolderEditKind.Rename ? original.Name : "";
                    field.SelectedIndex = (int)(original.Sort?.Field ?? SynologyPhotoSortField.TakenTime); direction.SelectedIndex = original.Sort?.Descending == true ? 1 : 0;
                    name.Visibility = Visible(kind != SynologyPhotoFolderEditKind.Sort); field.Visibility = direction.Visibility = Visible(kind == SynologyPhotoFolderEditKind.Sort);
                    fields.Visibility = Visibility.Visible; message.Visibility = Visibility.Collapsed; dialog.IsPrimaryButtonEnabled = true;
                }
            }
            catch (Exception error) { if (Current()) message.Text = _l.Get(ManagementErrorKey(error)); }
            finally { if (Current()) { progress.IsActive = false; progress.Visibility = Visibility.Collapsed; } }
            await showing;
        }
        finally { closed = true; _managementPreparing = false; if (ReferenceEquals(_dialog, dialog)) SetPhotoDialog(null); RenderManagementControls(); }
        if (submitted is not null && !_disposed && generation == _viewGeneration)
        { await _model.ApplyFolderChangeAsync(submitted); if (!_disposed && generation == _viewGeneration) await ShowFolderChangesAsync(submitted.Id); }
    }
    private async Task ShowFolderChangesAsync(Guid? selected = null)
    {
        if (_disposed || _dialog is not null) return;
        var generation = _viewGeneration; var closed = false; var busy = false; var values = new Dictionary<Guid, SynologyPhotoFolderChange>();
        var picker = new ComboBox { Header = _l.Get("PhotosFolderChanges"), HorizontalAlignment = HorizontalAlignment.Stretch };
        var message = new TextBlock { TextWrapping = TextWrapping.Wrap }; var target = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var refresh = QueueButton("PhotosRefresh"); var resume = QueueButton("PhotosContinueChanges"); var cancel = QueueButton("PhotosCancelRemainingChanges");
        var progress = new ProgressRing { Width = 24, Height = 24, HorizontalAlignment = HorizontalAlignment.Left };
        var actions = new StackPanel { Spacing = 8 }; var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 }; row.Children.Add(refresh); row.Children.Add(resume); actions.Children.Add(row); actions.Children.Add(cancel);
        var panel = new StackPanel { MinWidth = 290, MaxWidth = 560, Spacing = 12 }; foreach (var child in new FrameworkElement[] { picker, progress, target, message, actions }) panel.Children.Add(child);
        var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = _l.Get("PhotosFolderChanges"), CloseButtonText = _l.Get("PhotosClose"),
            Content = new ScrollViewer { Content = panel, MaxHeight = 530 } };
        bool Current() => !closed && !_disposed && generation == _viewGeneration;
        SynologyPhotoFolderChange? Selected() => picker.SelectedItem is PhotoFolderChangeChoice choice ? values.GetValueOrDefault(choice.Id) : null;
        void Render()
        {
            var value = Selected(); target.Text = value is null ? "" : value.Edit.Name ?? value.Edit.Folder.Name;
            message.Text = value is null ? _l.Get("PhotosChangesEmpty") : value.State == SynologyPhotoChangeState.Failed && value.Failure is { } failure
                ? _l.Get(ManagementErrorKey(new SynologyPhotoException(failure))) : ChangeStateText(value.State);
            picker.IsEnabled = !busy; resume.IsEnabled = !busy && value?.CanContinue == true; refresh.IsEnabled = !busy;
            cancel.IsEnabled = !busy && value?.State is SynologyPhotoChangeState.Ready or SynologyPhotoChangeState.Failed;
            progress.IsActive = busy; progress.Visibility = Visible(busy);
        }
        async Task Load(int action = 0)
        {
            if (!Current() || busy) return; var choice = Selected(); busy = true; Render();
            try
            {
                if (choice is not null && action != 0)
                {
                    var result = action == 1 ? await _model.Repository.ReviewFolderChangeAsync(choice.Id) : action == 2 ? await _model.Repository.ContinueFolderChangeAsync(choice.Id) : await _model.Repository.CancelFolderChangeAsync(choice.Id);
                    if (Current()) await ApplyFolderResultAsync(result);
                }
                var changes = await _model.Repository.FolderChangesAsync(); if (!Current()) return;
                values = changes.ToDictionary(change => change.Id); var id = choice?.Id ?? selected;
                var entries = changes.Select((change, index) => new PhotoFolderChangeChoice(change.Id, _l.Format("PhotosChangeChoice", index + 1, FolderEditTitle(change.Edit.Kind)))).ToArray();
                picker.ItemsSource = entries; picker.SelectedIndex = entries.Length == 0 ? -1 : Math.Max(0, Array.FindIndex(entries, item => item.Id == id));
            }
            catch (Exception error) { if (Current()) message.Text = _l.Get(ManagementErrorKey(error)); return; }
            finally { busy = false; if (Current()) { progress.IsActive = false; progress.Visibility = Visibility.Collapsed; refresh.IsEnabled = true; picker.IsEnabled = true; } }
            Render();
        }
        picker.SelectionChanged += (_, _) => Render(); refresh.Click += async (_, _) => await Load(1); resume.Click += async (_, _) => await Load(2); cancel.Click += async (_, _) => await Load(3);
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(15) };
        timer.Tick += async (_, _) => { if (Selected()?.State is SynologyPhotoChangeState.Submitting or SynologyPhotoChangeState.PendingReview) await Load(1); };
        dialog.Closed += (_, _) => { closed = true; timer.Stop(); };
        try { SetPhotoDialog(dialog); await _model.Automatic.YieldAsync(); var showing = ShowPhotoDialogAsync(dialog); timer.Start(); await Load(); await showing; }
        finally { closed = true; timer.Stop(); if (ReferenceEquals(_dialog, dialog)) SetPhotoDialog(null); }
    }
}
