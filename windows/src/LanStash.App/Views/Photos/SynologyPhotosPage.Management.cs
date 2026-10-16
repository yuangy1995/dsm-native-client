using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views.Photos;

public sealed partial class SynologyPhotosPage
{
    private bool _photoSelectionMode, _managementPreparing;
    private sealed record PhotoEditChoice(SynologyPhotoEditKind Kind, string Title) { public override string ToString() => Title; }
    private sealed record PhotoChangeChoice(Guid Id, string Title) { public override string ToString() => Title; }
    private sealed class PhotoEditInputException(string key) : Exception { internal string Key { get; } = key; }
    private void SelectPhotos_Click(object sender, RoutedEventArgs args) => SetPhotoSelection(!_photoSelectionMode);
    private void SetPhotoSelection(bool selected)
    {
        _photoSelectionMode = selected;
        if (LibraryGrid.SelectionMode == ListViewSelectionMode.Multiple) LibraryGrid.SelectedItems.Clear();
        else LibraryGrid.SelectedItem = null;
        LibraryGrid.SelectionMode = selected ? ListViewSelectionMode.Multiple : ListViewSelectionMode.Single;
        LibraryGrid.IsItemClickEnabled = !selected; RenderManagementControls();
    }
    private void PhotoSelection_Changed(object sender, SelectionChangedEventArgs args) { if (_ready) RenderManagementControls(); }
    private SynologyPhoto[] SelectedManagementPhotos() => LibraryGrid.SelectedItems.OfType<SynologyPhotoCell>().Select(cell => cell.Photo).OfType<SynologyPhoto>().ToArray();
    private void RenderManagementControls()
    {
        if (!_ready || _disposed) return;
        var enabled = _model.Repository.SupportsManagement;
        SelectPhotosMenu.Visibility = EditPhotosMenu.Visibility = CreatePhotoTagMenu.Visibility = PhotoChangesMenu.Visibility = Visible(enabled);
        SelectPhotosMenu.Visibility = Visibility.Visible;
        CreatePhotoTagMenu.Text = _l.Get("PhotosCreateTag");
        CreatePhotoTagMenu.IsEnabled = !_managementPreparing && !_model.IsLoading && _model.HasOriginalSource;
        SelectPhotosMenu.Text = _l.Get(_photoSelectionMode ? "PhotosFinishSelection" : "PhotosSelectItems");
        SelectPhotosMenu.IsEnabled = !_managementPreparing && !_model.IsLoading;
        var count = SelectedManagementPhotos().Length;
        EditPhotosMenu.Text = _l.Get(count > 100 ? "PhotosEditSelectionLimit" : "PhotosEditDetails");
        EditPhotosMenu.IsEnabled = !_managementPreparing && _photoSelectionMode && count is > 0 and <= 100 && count == LibraryGrid.SelectedItems.Count;
        RenderFolderControls();
        RenderFileControls();
        RenderAlbumControls();
        RenderPeopleControls();
        RenderExportControls();
        RenderPreviewGenerationControls();
    }
    private async void EditPhotos_Click(object sender, RoutedEventArgs args) => await ShowPhotoEditAsync(SelectedManagementPhotos());
    private async void EditPreviewPhoto_Click(object sender, RoutedEventArgs args)
    { if (_model.Preview.Photo is { } photo) await ShowPhotoEditAsync([photo]); }
    private async void PhotoChanges_Click(object sender, RoutedEventArgs args) => await ShowPhotoChangesAsync();
    private async void CreatePhotoTag_Click(object sender, RoutedEventArgs args) =>
        await ShowPhotoEditAsync([], SynologyPhotoEditKind.CreateTag, _model.SelectedSpace);
    private string PhotoEditTitle(SynologyPhotoEditKind kind) => _l.Get(kind switch
    {
        SynologyPhotoEditKind.Description => "PhotosEditDescription", SynologyPhotoEditKind.Rating => "PhotosEditRating",
        SynologyPhotoEditKind.Date => "PhotosEditDate", SynologyPhotoEditKind.ShiftDates => "PhotosShiftDates",
        SynologyPhotoEditKind.AddTags => "PhotosAddTags", SynologyPhotoEditKind.RemoveTags => "PhotosRemoveTags",
        SynologyPhotoEditKind.CreateTag => "PhotosCreateTag", _ => "PhotosRotateLeft",
    });
    private static string ManagementErrorKey(Exception error) => error is PhotoEditInputException input ? input.Key : error is SynologyPhotoException photo ? photo.Failure switch
    {
        SynologyPhotoFailure.Permission => "PhotosEditPermission", SynologyPhotoFailure.TargetChanged => "PhotosEditTargetChanged",
        SynologyPhotoFailure.UploadBusy => "PhotosEditBusy", SynologyPhotoFailure.RecoveryUnavailable => "PhotosEditRecoveryUnavailable",
        SynologyPhotoFailure.Unavailable => "PhotosEditUnavailable",
        SynologyPhotoFailure.SessionExpired => "PhotosUploadSignInAgain", _ => "PhotosEditFailed",
    } : error is DsmException { AuthenticationFailure: true } ? "PhotosUploadSignInAgain" : error is DsmException { Code: 105 } ? "PhotosEditPermission" : "PhotosEditFailed";

    private async Task ShowPhotoEditAsync(IReadOnlyList<SynologyPhoto> selection, SynologyPhotoEditKind? initialKind = null, SynologyPhotoSpace? source = null)
    {
        var standaloneTag = selection.Count == 0 && initialKind == SynologyPhotoEditKind.CreateTag;
        if (_disposed || _dialog is not null || _managementPreparing || selection.Count > 100 || selection.Count == 0 && !standaloneTag) return;
        var space = source ?? (selection.Count > 0 ? selection[0].Id.Space : _model.SelectedSpace);
        _managementPreparing = true; RenderManagementControls(); var generation = _viewGeneration; var closed = false;
        var photos = new List<SynologyPhoto>(); var loadingTags = false; var tagsLoaded = false;
        var choices = new ComboBox { Header = _l.Get("PhotosEditField"), HorizontalAlignment = HorizontalAlignment.Stretch };
        var text = new TextBox { Header = _l.Get("PhotosEditDescription"), AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 100 };
        var rating = new ComboBox { Header = _l.Get("PhotosEditRating"), HorizontalAlignment = HorizontalAlignment.Stretch,
            ItemsSource = Enumerable.Range(0, 6).Select(value => value == 0 ? _l.Get("PhotosNoRating") : value == 1 ? _l.Get("PhotosRatingOne") : _l.Format("PhotosRatingValue", value)).ToArray(), SelectedIndex = 0 };
        var date = new CalendarDatePicker { Header = _l.Get("PhotosEditDate"), HorizontalAlignment = HorizontalAlignment.Stretch };
        var time = new TimePicker { Header = _l.Get("PhotosEditTime") };
        var amount = new NumberBox { Header = _l.Get("PhotosDateOffset"), Value = 1, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Inline };
        var unit = new ComboBox { Header = _l.Get("PhotosDateOffsetUnit"), ItemsSource = new[] { _l.Get("PhotosMinutes"), _l.Get("PhotosHours"), _l.Get("PhotosDays") }, SelectedIndex = 1 };
        var tagList = new ListView { SelectionMode = ListViewSelectionMode.Multiple, DisplayMemberPath = nameof(SynologyPhotoChoice.Name), MaxHeight = 240 };
        AutomationProperties.SetName(tagList, _l.Get("PhotosChooseTags"));
        var tagName = new TextBox { Header = _l.Get("PhotosTagName") };
        var message = new TextBlock { TextWrapping = TextWrapping.Wrap, Text = _l.Get("PhotosLoadingDescription") };
        var error = new InfoBar { Severity = InfoBarSeverity.Error, IsClosable = false };
        var spinner = new ProgressRing { IsActive = true, Width = 24, Height = 24, HorizontalAlignment = HorizontalAlignment.Left };
        var fields = new StackPanel { Spacing = 12, Visibility = Visibility.Collapsed };
        foreach (var child in new FrameworkElement[] { choices, text, rating, date, time, amount, unit, tagList, tagName }) fields.Children.Add(child);
        var panel = new StackPanel { MinWidth = 290, MaxWidth = 620, Spacing = 12 };
        foreach (var child in new FrameworkElement[] { spinner, message, fields, error }) panel.Children.Add(child);
        var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = _l.Get(standaloneTag ? "PhotosCreateTag" : "PhotosEditDetails"),
            PrimaryButtonText = _l.Get(standaloneTag ? "PhotosCreateTag" : "PhotosSaveChanges"), CloseButtonText = _l.Get("PhotosCancel"), IsPrimaryButtonEnabled = false,
            Content = new ScrollViewer { Content = panel, MaxHeight = 570, VerticalScrollBarVisibility = ScrollBarVisibility.Auto } };
        SynologyPhotoChange? submitted = null;
        bool Current() => !closed && !_disposed && generation == _viewGeneration;
        void RenderFields()
        {
            if (choices.SelectedItem is not PhotoEditChoice choice) return;
            foreach (var control in new FrameworkElement[] { text, rating, date, time, amount, unit, tagList, tagName }) control.Visibility = Visibility.Collapsed;
            switch (choice.Kind)
            {
                case SynologyPhotoEditKind.Description: text.Visibility = Visibility.Visible; break;
                case SynologyPhotoEditKind.Rating: rating.Visibility = Visibility.Visible; break;
                case SynologyPhotoEditKind.Date: date.Visibility = time.Visibility = Visibility.Visible; break;
                case SynologyPhotoEditKind.ShiftDates: amount.Visibility = unit.Visibility = Visibility.Visible; break;
                case SynologyPhotoEditKind.AddTags or SynologyPhotoEditKind.RemoveTags: tagList.Visibility = Visibility.Visible; break;
                case SynologyPhotoEditKind.CreateTag: tagName.Visibility = Visibility.Visible; break;
            }
            var tagEdit = choice.Kind is SynologyPhotoEditKind.AddTags or SynologyPhotoEditKind.RemoveTags;
            message.Text = tagEdit && tagsLoaded && tagList.Items.Count == 0 ? _l.Get("PhotosNoTags") :
                choice.Kind == SynologyPhotoEditKind.Rotate ? _l.Get("PhotosRotateDescription") : "";
            message.Visibility = Visible(message.Text.Length > 0); spinner.IsActive = loadingTags; spinner.Visibility = Visible(loadingTags);
            dialog.IsPrimaryButtonEnabled = (photos.Count > 0 || standaloneTag) && !loadingTags && (!tagEdit || tagsLoaded && tagList.SelectedItems.Count > 0);
        }
        async Task LoadTags()
        {
            if (tagsLoaded || loadingTags || photos.Count == 0) return; loadingTags = true; RenderFields();
            try
            {
                var tags = new List<SynologyPhotoChoice>(); var seen = new HashSet<long>();
                for (var offset = 0; ; offset += 500)
                {
                    var page = await _model.Repository.TagsAsync(photos[0].Id.Space, offset, 500, _viewCancellation.Token);
                    foreach (var tag in page) { if (!seen.Add(tag.Id)) throw new SynologyPhotoException(SynologyPhotoFailure.InvalidResponse); tags.Add(tag); }
                    if (page.Count < 500) break;
                }
                if (!Current()) return; tagList.ItemsSource = tags; tagsLoaded = true; error.IsOpen = false;
            }
            catch (Exception exception) { if (Current()) { error.Message = _l.Get(ManagementErrorKey(exception)); error.IsOpen = true; } }
            finally { loadingTags = false; if (Current()) RenderFields(); }
        }
        choices.SelectionChanged += async (_, _) =>
        { RenderFields(); if (choices.SelectedItem is PhotoEditChoice { Kind: SynologyPhotoEditKind.AddTags or SynologyPhotoEditKind.RemoveTags }) await LoadTags(); };
        tagList.SelectionChanged += (_, _) => RenderFields();
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true; var deferral = args.GetDeferral(); dialog.IsPrimaryButtonEnabled = false;
            foreach (var control in fields.Children.OfType<Control>()) control.IsEnabled = false;
            try
            {
                if (choices.SelectedItem is not PhotoEditChoice choice || !Current()) return;
                var edit = new SynologyPhotoEdit(choice.Kind, photos.ToArray()) { Space = space };
                edit = choice.Kind switch
                {
                    SynologyPhotoEditKind.Description => edit with { Text = text.Text },
                    SynologyPhotoEditKind.Rating => edit with { Value = rating.SelectedIndex },
                    SynologyPhotoEditKind.Date => edit with { Value = EditedPhotoTimestamp(date.Date, time.Time) },
                    SynologyPhotoEditKind.ShiftDates => edit with { Value = PhotoDateOffset(amount.Value, unit.SelectedIndex) },
                    SynologyPhotoEditKind.AddTags or SynologyPhotoEditKind.RemoveTags => edit with { TagIds = tagList.SelectedItems.Cast<SynologyPhotoChoice>().Select(tag => tag.Id).ToArray() },
                    SynologyPhotoEditKind.CreateTag => edit with { Text = tagName.Text },
                    _ => edit,
                };
                if (edit.Kind == SynologyPhotoEditKind.CreateTag && string.IsNullOrWhiteSpace(edit.Text)) throw new PhotoEditInputException("PhotosEditTagNameRequired");
                if (edit.Kind == SynologyPhotoEditKind.ShiftDates)
                {
                    try { foreach (var photo in photos) { var expected = checked(photo.TakenAt.ToUnixTimeSeconds() + edit.Value!.Value); if (expected < 0) throw new ArgumentOutOfRangeException(); DateTimeOffset.FromUnixTimeSeconds(expected); } }
                    catch (Exception exception) when (exception is OverflowException or ArgumentOutOfRangeException) { throw new PhotoEditInputException("PhotosEditOffsetInvalid"); }
                }
                spinner.IsActive = true; spinner.Visibility = Visibility.Visible; error.IsOpen = false;
                submitted = await _model.Repository.EditAsync(Guid.NewGuid(), edit);
                if (Current()) args.Cancel = false;
            }
            catch (Exception exception) { if (Current()) { error.Message = _l.Get(ManagementErrorKey(exception)); error.IsOpen = true; } }
            finally
            {
                if (Current()) { foreach (var control in fields.Children.OfType<Control>()) control.IsEnabled = true; RenderFields(); }
                deferral.Complete();
            }
        };
        dialog.Closed += (_, _) => closed = true;
        async Task Load()
        {
            try
            {
                foreach (var photo in selection) photos.Add(await _model.Repository.DetailsAsync(photo, _viewCancellation.Token));
                if (!Current()) return;
                var mixed = photos.Select(photo => photo.Id.Space).Distinct().Count() > 1;
                var kinds = (standaloneTag ? new[] { SynologyPhotoEditKind.CreateTag } : Enum.GetValues<SynologyPhotoEditKind>()).Where(kind => !mixed || kind is SynologyPhotoEditKind.Rating or SynologyPhotoEditKind.Date or SynologyPhotoEditKind.ShiftDates)
                    .Where(kind => kind != SynologyPhotoEditKind.Rotate || photos.Count == 1 && photos[0].SupportsRotation).ToArray();
                choices.ItemsSource = kinds.Select(kind => new PhotoEditChoice(kind, PhotoEditTitle(kind))).ToArray();
                text.Text = photos.Count == 1 ? photos[0].Description ?? "" : ""; rating.SelectedIndex = photos.Count == 1 ? photos[0].Rating ?? 0 : 0;
                if (photos.Count > 0) { date.Date = photos[0].TakenAt.ToLocalTime(); time.Time = photos[0].TakenAt.LocalDateTime.TimeOfDay; }
                choices.Visibility = Visible(!standaloneTag);
                choices.SelectedIndex = Math.Max(0, Array.IndexOf(kinds, initialKind ?? kinds[0])); fields.Visibility = Visibility.Visible;
                spinner.IsActive = false; spinner.Visibility = Visibility.Collapsed; RenderFields();
            }
            catch (Exception exception) { if (Current()) { spinner.IsActive = false; spinner.Visibility = Visibility.Collapsed; message.Text = _l.Get(ManagementErrorKey(exception)); } }
        }
        try { SetPhotoDialog(dialog); await _model.Automatic.YieldAsync(); var showing = ShowPhotoDialogAsync(dialog); await Load(); await showing; }
        finally { closed = true; _managementPreparing = false; if (ReferenceEquals(_dialog, dialog)) SetPhotoDialog(null); RenderManagementControls(); }
        if (submitted is not null && !_disposed && generation == _viewGeneration)
        {
            await ApplyPhotoChangeAsync(submitted);
            if (_disposed || generation != _viewGeneration) return;
            await ShowPhotoChangesAsync(submitted.Id);
        }
    }
    private async Task ApplyPhotoChangeAsync(SynologyPhotoChange change)
    {
        var generation = _viewGeneration;
        if (change.Kind == SynologyPhotoEditKind.Rotate && change.Items.Any(item => item.State == SynologyPhotoChangeState.Completed && item.Updated is not null))
        { CancelThumbnails(); _thumbnails.Clear(); }
        await _model.ApplyConfirmedChangesAsync(change.Id, change.Items);
        if (_disposed || generation != _viewGeneration) return;
        if (_model.Preview.Photo is { } preview && change.Items.FirstOrDefault(item => item.State == SynologyPhotoChangeState.Completed &&
            item.Original.IsSameDeletionTarget(preview) && item.Original.AlbumContext == preview.AlbumContext)?.Updated is { } updated)
            await _model.Preview.OpenAsync(updated);
    }
    private static long EditedPhotoTimestamp(DateTimeOffset? date, TimeSpan time)
    {
        if (date is null) throw new PhotoEditInputException("PhotosEditDateInvalid");
        var local = DateTime.SpecifyKind(date.Value.Date + time, DateTimeKind.Unspecified);
        if (TimeZoneInfo.Local.IsInvalidTime(local)) throw new PhotoEditInputException("PhotosEditDateInvalid");
        var result = new DateTimeOffset(local, TimeZoneInfo.Local.GetUtcOffset(local)).ToUnixTimeSeconds();
        return result >= 0 ? result : throw new PhotoEditInputException("PhotosEditDateInvalid");
    }
    private static long PhotoDateOffset(double amount, int unit)
    {
        if (!double.IsFinite(amount) || amount != Math.Truncate(amount) || Math.Abs(amount) > int.MaxValue || unit is < 0 or > 2)
            throw new PhotoEditInputException("PhotosEditOffsetInvalid");
        return checked((long)amount * new[] { 60L, 3600L, 86400L }[unit]);
    }
}
