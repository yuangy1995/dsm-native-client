using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views.Photos;

public sealed partial class SynologyPhotosPage
{
    private SynologyPhotoCollection? SelectedPerson() => _model.Category == SynologyPhotoCategory.People ? _model.CategoryItem ??
        (LibraryGrid.SelectedItems.Count == 1 ? (LibraryGrid.SelectedItems[0] as SynologyPhotoCell)?.Collection : null) : null;
    private void RenderPeopleControls()
    {
        var supported = _model.Repository.SupportsRecognitionManagement;
        RenamePhotoPersonMenu.Visibility = MergePhotoPeopleMenu.Visibility = ShowPhotoPeopleMenu.Visibility = PhotoRecognitionChangesMenu.Visibility = Visible(supported);
        RemovePhotoFacesMenu.Visibility = ReassignPhotoFacesMenu.Visibility = SetPhotoPersonCoverMenu.Visibility = Visible(supported);
        RemovePhotoFacesMenu.Text = _l.Get("PhotosRemovePersonFaces"); ReassignPhotoFacesMenu.Text = _l.Get("PhotosReassignPersonFaces"); SetPhotoPersonCoverMenu.Text = _l.Get("PhotosSetPersonCover");
        RenamePhotoPersonMenu.Text = _l.Get("PhotosRenamePerson"); MergePhotoPeopleMenu.Text = _l.Get("PhotosMergePeople");
        ShowPhotoPeopleMenu.Text = _l.Get("PhotosPeopleDisplay"); PhotoRecognitionChangesMenu.Text = _l.Get("PhotosRecognitionChanges");
        PhotoRecognitionHistoryButton.Content = _l.Get("PhotosRecognitionChanges");
        var enabled = supported && !_managementPreparing && !_model.IsLoading && _model.HasOriginalSource &&
            _model.Categories.Contains(SynologyPhotoCategory.People) && (_model.SelectedSpace == SynologyPhotoSpace.Personal || _model.CanManageSharedSpace);
        ShowPhotoPeopleMenu.IsEnabled = enabled;
        RenamePhotoPersonMenu.IsEnabled = MergePhotoPeopleMenu.IsEnabled = enabled && SelectedPerson() is not null;
        var photos = SelectedManagementPhotos();
        RemovePhotoFacesMenu.IsEnabled = ReassignPhotoFacesMenu.IsEnabled = enabled && _model.Category == SynologyPhotoCategory.People && _model.CategoryItem is not null &&
            photos.Length is > 0 and <= 100 && photos.Length == LibraryGrid.SelectedItems.Count;
        SetPhotoPersonCoverMenu.IsEnabled = RemovePhotoFacesMenu.IsEnabled && photos.Length == 1;
        ShowPhotoConceptsMenu.Text = _l.Get("PhotosConceptDisplay"); SetPhotoConceptCoverMenu.Text = _l.Get("PhotosSetConceptCover"); RemovePhotoConceptItemsMenu.Text = _l.Get("PhotosRemoveConceptPhotos");
        var concepts = _model.Repository.SupportsConceptManagement(_model.SelectedSpace);
        ShowPhotoConceptsMenu.Visibility = SetPhotoConceptCoverMenu.Visibility = RemovePhotoConceptItemsMenu.Visibility = Visible(concepts);
        ShowPhotoConceptsMenu.IsEnabled = concepts && !_managementPreparing && !_model.IsLoading && _model.HasOriginalSource && _model.Categories.Contains(SynologyPhotoCategory.Subjects);
        RemovePhotoConceptItemsMenu.IsEnabled = ShowPhotoConceptsMenu.IsEnabled && _model.Category == SynologyPhotoCategory.Subjects && _model.CategoryItem is not null &&
            photos.Length is > 0 and <= 100 && photos.Length == LibraryGrid.SelectedItems.Count;
        SetPhotoConceptCoverMenu.IsEnabled = RemovePhotoConceptItemsMenu.IsEnabled && photos.Length == 1;
        RenderSimilarControls();
    }
    private async void RenamePhotoPerson_Click(object sender, RoutedEventArgs args) => await ShowRecognitionEditAsync(SynologyPhotoRecognitionKind.RenamePerson, SelectedPerson());
    private async void MergePhotoPeople_Click(object sender, RoutedEventArgs args) => await ShowRecognitionEditAsync(SynologyPhotoRecognitionKind.MergePeople, SelectedPerson());
    private async void ShowPhotoPeople_Click(object sender, RoutedEventArgs args) => await ShowRecognitionEditAsync(SynologyPhotoRecognitionKind.ShowPeople, null);
    private async void PhotoRecognitionChanges_Click(object sender, RoutedEventArgs args) => await ShowRecognitionChangesAsync();
    private async void RemovePhotoFaces_Click(object sender, RoutedEventArgs args) => await ShowRecognitionEditAsync(SynologyPhotoRecognitionKind.RemovePersonFaces, _model.CategoryItem, SelectedManagementPhotos());
    private async void ReassignPhotoFaces_Click(object sender, RoutedEventArgs args) => await ShowRecognitionEditAsync(SynologyPhotoRecognitionKind.ReassignPersonFaces, _model.CategoryItem, SelectedManagementPhotos());
    private async void SetPhotoPersonCover_Click(object sender, RoutedEventArgs args) => await ShowRecognitionEditAsync(SynologyPhotoRecognitionKind.SetPersonCover, _model.CategoryItem, SelectedManagementPhotos());
    private async void ShowPhotoConcepts_Click(object sender, RoutedEventArgs args) => await ShowRecognitionEditAsync(SynologyPhotoRecognitionKind.ShowConcepts, null);
    private async void SetPhotoConceptCover_Click(object sender, RoutedEventArgs args) => await ShowRecognitionEditAsync(SynologyPhotoRecognitionKind.SetConceptCover, _model.CategoryItem, SelectedManagementPhotos());
    private async void RemovePhotoConceptItems_Click(object sender, RoutedEventArgs args) => await ShowRecognitionEditAsync(SynologyPhotoRecognitionKind.RemoveConceptPhotos, _model.CategoryItem, SelectedManagementPhotos());
    private static bool ConceptEdit(SynologyPhotoRecognitionKind kind) => kind is SynologyPhotoRecognitionKind.ShowConcepts or SynologyPhotoRecognitionKind.SetConceptCover or SynologyPhotoRecognitionKind.RemoveConceptPhotos;
    private static bool PersonPhotoEdit(SynologyPhotoRecognitionKind kind) => kind is SynologyPhotoRecognitionKind.RemovePersonFaces or SynologyPhotoRecognitionKind.ReassignPersonFaces or SynologyPhotoRecognitionKind.SetPersonCover;
    private string RecognitionTitle(SynologyPhotoRecognitionKind kind) => _l.Get(kind switch
    { SynologyPhotoRecognitionKind.RenamePerson => "PhotosRenamePerson", SynologyPhotoRecognitionKind.MergePeople => "PhotosMergePeople",
        SynologyPhotoRecognitionKind.RemovePersonFaces => "PhotosRemovePersonFaces", SynologyPhotoRecognitionKind.ReassignPersonFaces => "PhotosReassignPersonFaces",
        SynologyPhotoRecognitionKind.SetPersonCover => "PhotosSetPersonCover", SynologyPhotoRecognitionKind.ManualFaces => "PhotosManualFaces",
        SynologyPhotoRecognitionKind.ShowConcepts => "PhotosConceptDisplay", SynologyPhotoRecognitionKind.SetConceptCover => "PhotosSetConceptCover", SynologyPhotoRecognitionKind.RemoveConceptPhotos => "PhotosRemoveConceptPhotos",
        SynologyPhotoRecognitionKind.SimilarTopPick => "PhotosSimilarTopPick", SynologyPhotoRecognitionKind.SimilarRemove => "PhotosSimilarRemove", SynologyPhotoRecognitionKind.SimilarUngroup => "PhotosSimilarUngroup", SynologyPhotoRecognitionKind.SimilarUndo => "PhotosSimilarUndo", _ => "PhotosPeopleDisplay" });
    private async Task ShowRecognitionEditAsync(SynologyPhotoRecognitionKind kind, SynologyPhotoCollection? target, IReadOnlyList<SynologyPhoto>? photos = null)
    {
        if (_disposed || _dialog is not null || _managementPreparing || kind is not (SynologyPhotoRecognitionKind.ShowPeople or SynologyPhotoRecognitionKind.ShowConcepts) && target is null) return;
        _managementPreparing = true; RenderManagementControls(); var generation = _viewGeneration; var space = target?.Space ?? _model.SelectedSpace; var closed = false; var busy = false;
        FrameworkElement? editor = null; Func<SynologyPhotoRecognitionEdit?>? input = null; SynologyPhotoRecognitionEdit? frozen = null; SynologyPhotoRecognitionChange? submitted = null;
        var allowed = kind switch { SynologyPhotoRecognitionKind.MergePeople => _model.Repository.RecognitionSafety.MergePeople,
            SynologyPhotoRecognitionKind.RemoveConceptPhotos => _model.Repository.RecognitionSafety.RemoveConceptPhotos,
            SynologyPhotoRecognitionKind.RemovePersonFaces or SynologyPhotoRecognitionKind.ReassignPersonFaces => _model.Repository.RecognitionSafety.CorrectFaces, _ => true };
        var body = new ContentControl { HorizontalContentAlignment = HorizontalAlignment.Stretch };
        var message = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var restriction = new TextBlock { TextWrapping = TextWrapping.Wrap, Text = allowed ? "" : _l.Get(ConceptEdit(kind) ? "PhotosConceptRemovalRestricted" : PersonPhotoEdit(kind) ? "PhotosFacesRestricted" : "PhotosPeopleMergeRestricted") };
        var retry = QueueButton("PhotosRetry"); var spinner = new ProgressRing { Width = 24, Height = 24, HorizontalAlignment = HorizontalAlignment.Left };
        var panel = new StackPanel { MinWidth = 290, MaxWidth = 580, Spacing = 12 };
        if (kind == SynologyPhotoRecognitionKind.MergePeople && target is not null) panel.Children.Add(new TextBlock { Text = _l.Format("PhotosPeopleMergeTarget", PersonName(target)), TextWrapping = TextWrapping.Wrap });
        foreach (var control in new FrameworkElement[] { spinner, message, restriction, retry, body }) panel.Children.Add(control);
        var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = RecognitionTitle(kind),
            PrimaryButtonText = _l.Get(kind is SynologyPhotoRecognitionKind.RenamePerson or SynologyPhotoRecognitionKind.SetPersonCover or SynologyPhotoRecognitionKind.SetConceptCover ? "PhotosSaveChanges" : "PhotosShareContinue"),
            CloseButtonText = _l.Get("PhotosCancel"), DefaultButton = ContentDialogButton.Close, IsPrimaryButtonEnabled = false,
            Content = new ScrollViewer { Content = panel, MaxHeight = 560 } };
        bool Current() => !closed && !_disposed && generation == _viewGeneration;
        void Render()
        {
            if (!Current()) return; body.IsEnabled = !busy; spinner.IsActive = busy; spinner.Visibility = Visible(busy);
            retry.Visibility = Visible(editor is null && !busy); retry.IsEnabled = !busy; message.Visibility = Visible(message.Text.Length > 0);
            restriction.Visibility = Visible(restriction.Text.Length > 0);
            dialog.IsPrimaryButtonEnabled = !busy && input?.Invoke() is not null && allowed;
        }
        async Task Load()
        {
            if (!Current() || busy) return; busy = true; message.Text = _l.Get("PhotosLoadingDescription"); Render();
            try
            {
                if (ConceptEdit(kind))
                {
                    var values = target is null ? await _model.Repository.ConceptsAsync(space, _viewCancellation.Token) :
                        new[] { await _model.Repository.ConceptAsync(target.Id, space, _viewCancellation.Token) };
                    if (!Current()) return;
                    if (target is not null && (values[0].Concept.Name != target.Name || target.Count is { } count && values[0].Concept.Count != count))
                        throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
                    if (kind == SynologyPhotoRecognitionKind.RemoveConceptPhotos && (values[0].Concept.Count is not { } total || values[0].DisplayThreshold is null || photos is null || total < photos.Count))
                        throw new SynologyPhotoException(SynologyPhotoFailure.InvalidResponse);
                    var form = new SynologyPhotoConceptEditor(kind, space, values, photos ?? []); form.Changed += Render; editor = form; input = form.Input; body.Content = editor;
                    message.Text = ""; return;
                }
                var people = await _model.Repository.PeopleAsync(space, kind == SynologyPhotoRecognitionKind.ShowPeople, _viewCancellation.Token);
                if (!Current()) return; SynologyPhotoPerson? original = null;
                if (target is not null)
                {
                    original = people.SingleOrDefault(person => person.Person.Id == target.Id);
                    if (original is null || original.Person.Name != target.Name || target.Count is { } count && original.Person.Count != count)
                        throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
                }
                if (PersonPhotoEdit(kind))
                {
                    if (original is null || photos is not { Count: > 0 and <= 100 } || kind == SynologyPhotoRecognitionKind.SetPersonCover && photos.Count != 1) throw new SynologyPhotoException(SynologyPhotoFailure.InvalidResponse);
                    var faces = await _model.Repository.PersonFacesAsync(original.Person.Id, photos, _viewCancellation.Token); if (!Current()) return;
                    var form = new SynologyPhotoFacesEditor(kind, original, people, faces, photos); form.Changed += Render; editor = form; input = form.Input;
                    body.Content = editor; await form.LoadImagesAsync(_model.Repository, _viewCancellation.Token);
                }
                else { var form = new SynologyPhotoPeopleEditor(kind, space, original, people); form.Changed += Render; editor = form; input = form.Input; body.Content = editor; }
                if (Current()) message.Text = "";
            }
            catch (Exception error) { if (Current()) message.Text = _l.Get(ManagementErrorKey(error)); }
            finally { busy = false; Render(); }
        }
        retry.Click += async (_, _) => await Load(); dialog.Closed += (_, _) => closed = true;
        dialog.Closing += (_, args) => { if (busy && Current() && _windowVisible && IsLoaded && editor is not null) args.Cancel = true; };
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true; if (!Current() || busy || !allowed || input?.Invoke() is not { } edit) return; var deferral = args.GetDeferral(); busy = true; Render();
            try
            {
                await _model.Repository.PrepareRecognitionAsync(edit, _viewCancellation.Token);
                if (!Current()) return;
                if (kind is SynologyPhotoRecognitionKind.RenamePerson or SynologyPhotoRecognitionKind.SetPersonCover or SynologyPhotoRecognitionKind.SetConceptCover) submitted = await _model.Repository.EditRecognitionAsync(Guid.NewGuid(), edit);
                else frozen = edit;
                if (Current()) args.Cancel = false;
            }
            catch (Exception error) { if (Current()) message.Text = _l.Get(ManagementErrorKey(error)); }
            finally { busy = false; Render(); deferral.Complete(); }
        };
        try
        {
            SetPhotoDialog(dialog); await _model.Automatic.YieldAsync(); Render(); var showing = ShowPhotoDialogAsync(dialog); await Load(); await showing; if (ReferenceEquals(_dialog, dialog)) SetPhotoDialog(null);
            if (frozen is not null && !_disposed && generation == _viewGeneration && _windowVisible) submitted = await ConfirmRecognitionAsync(frozen);
        }
        finally { closed = true; _managementPreparing = false; if (ReferenceEquals(_dialog, dialog)) SetPhotoDialog(null); RenderManagementControls(); }
        if (submitted is not null && !_disposed && generation == _viewGeneration)
        { await _model.ApplyRecognitionChangeAsync(submitted); if (!_disposed && generation == _viewGeneration && _windowVisible) await ShowRecognitionChangesAsync(submitted.Id); }
    }
    private string PersonName(SynologyPhotoCollection person) => person.Name.Length == 0 ? _l.Get("PhotosPersonUnnamed") : person.Name;
    private async Task<SynologyPhotoRecognitionChange?> ConfirmRecognitionAsync(SynologyPhotoRecognitionEdit edit)
    {
        var generation = _viewGeneration; var closed = false; var busy = false; SynologyPhotoRecognitionChange? result = null;
        var panel = new StackPanel { MinWidth = 290, MaxWidth = 580, Spacing = 12 };
        panel.Children.Add(new TextBlock { Text = _l.Get(edit.Kind switch { SynologyPhotoRecognitionKind.MergePeople => "PhotosPeopleMergeRisk", SynologyPhotoRecognitionKind.RemovePersonFaces => "PhotosRemoveFacesConfirm",
            SynologyPhotoRecognitionKind.ReassignPersonFaces => "PhotosReassignFacesConfirm", SynologyPhotoRecognitionKind.ManualFaces => "PhotosManualConfirm",
            SynologyPhotoRecognitionKind.ShowConcepts => edit.Visible ? "PhotosConceptShowConfirm" : "PhotosConceptHideConfirm", SynologyPhotoRecognitionKind.RemoveConceptPhotos => "PhotosConceptRemoveConfirm",
            SynologyPhotoRecognitionKind.SimilarTopPick => "PhotosSimilarTopPickConfirm", SynologyPhotoRecognitionKind.SimilarRemove => "PhotosSimilarRemoveConfirm", SynologyPhotoRecognitionKind.SimilarUngroup => "PhotosSimilarUngroupConfirm", SynologyPhotoRecognitionKind.SimilarUndo => "PhotosSimilarUndoConfirm",
            _ => edit.Visible ? "PhotosPeopleShowConfirm" : "PhotosPeopleHideConfirm" }), TextWrapping = TextWrapping.Wrap });
        foreach (var concept in edit.Concepts) panel.Children.Add(new TextBlock { Text = concept.Concept.Name, TextWrapping = TextWrapping.Wrap });
        if (edit.SimilarGroups.Count > 0)
        {
            panel.Children.Add(new TextBlock { Text = _l.Format("PhotosSimilarSummary", edit.SimilarGroups.Count, edit.SimilarGroups.Sum(detail => detail.Photos.Count)), TextWrapping = TextWrapping.Wrap });
            foreach (var detail in edit.SimilarGroups)
                panel.Children.Add(new TextBlock { Text = _l.Format("PhotosSimilarGroupRow", detail.Photos.Single(photo => photo.Id.ItemId == detail.Group.TopPickId).Filename, detail.Group.Count), TextWrapping = TextWrapping.Wrap });
            foreach (var photo in edit.SimilarGroups.SelectMany(detail => detail.Photos).Where(photo => edit.SimilarSelection.Contains(photo.Id.ItemId)))
                panel.Children.Add(new TextBlock { Text = photo.Filename, TextWrapping = TextWrapping.Wrap });
        }
        if (edit.Kind == SynologyPhotoRecognitionKind.RemoveConceptPhotos)
        {
            panel.Children.Add(new TextBlock { Text = _l.Format("PhotosConceptPhotoSelection", edit.ConceptPhotos.Count), TextWrapping = TextWrapping.Wrap });
            if (edit.Concepts[0].Concept.Count - edit.ConceptPhotos.Count < edit.Concepts[0].DisplayThreshold)
                panel.Children.Add(new TextBlock { Text = _l.Get("PhotosConceptBelowThreshold"), TextWrapping = TextWrapping.Wrap });
        }
        if (edit.Kind == SynologyPhotoRecognitionKind.ManualFaces) panel.Children.Add(new TextBlock { Text = edit.ManualPhoto!.Filename, TextWrapping = TextWrapping.Wrap });
        if (PersonPhotoEdit(edit.Kind)) panel.Children.Add(new TextBlock { Text = _l.Format("PhotosFacesSelected", edit.Faces.Count), TextWrapping = TextWrapping.Wrap });
        foreach (var person in edit.People) panel.Children.Add(new TextBlock { Text = PersonName(person.Person), TextWrapping = TextWrapping.Wrap });
        if (edit.Name is not null) panel.Children.Add(new TextBlock { Text = _l.Format(PersonPhotoEdit(edit.Kind) ? "PhotosFaceDestinationName" : "PhotosPeopleFinalName", edit.Name), TextWrapping = TextWrapping.Wrap });
        var message = new TextBlock { TextWrapping = TextWrapping.Wrap }; panel.Children.Add(message);
        var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = RecognitionTitle(edit.Kind),
            PrimaryButtonText = edit.Kind == SynologyPhotoRecognitionKind.ShowConcepts ? _l.Get(edit.Visible ? "PhotosConceptShow" : "PhotosConceptHide") :
                edit.Kind == SynologyPhotoRecognitionKind.ShowPeople ? _l.Get(edit.Visible ? "PhotosPeopleShow" : "PhotosPeopleHide") : RecognitionTitle(edit.Kind),
            CloseButtonText = _l.Get("PhotosCancel"), DefaultButton = ContentDialogButton.Close, Content = new ScrollViewer { Content = panel, MaxHeight = 520 } };
        dialog.Closed += (_, _) => closed = true;
        dialog.Closing += (_, args) => { if (busy && !closed && !_disposed && _windowVisible && IsLoaded) args.Cancel = true; };
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true; if (busy || closed || _disposed || generation != _viewGeneration) return;
            var deferral = args.GetDeferral(); busy = true; dialog.IsPrimaryButtonEnabled = false;
            try { result = await _model.Repository.EditRecognitionAsync(Guid.NewGuid(), edit); if (!closed && !_disposed && generation == _viewGeneration) args.Cancel = false; }
            catch (Exception error) { if (!closed && !_disposed && generation == _viewGeneration) message.Text = _l.Get(ManagementErrorKey(error)); }
            finally { busy = false; dialog.IsPrimaryButtonEnabled = true; deferral.Complete(); }
        };
        try { SetPhotoDialog(dialog); await _model.Automatic.YieldAsync(); await ShowPhotoDialogAsync(dialog); } finally { if (ReferenceEquals(_dialog, dialog)) SetPhotoDialog(null); }
        return result;
    }
}
