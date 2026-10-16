using LanStash.App.Features.Photos.Synology;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views.Photos;

public sealed partial class SynologyPhotosPage
{
    private async void EditPhotoFaces_Click(object sender, RoutedEventArgs args)
    {
        if (_model.Preview.Photo is not { MediaType: not "video" } photo) return;
        _model.Preview.FinishMotion(); await ShowManualFacesAsync(photo);
    }
    private async Task ShowManualFacesAsync(SynologyPhoto original)
    {
        if (_disposed || _dialog is not null || _managementPreparing || !_model.Repository.SupportsRecognitionManagement || original.MediaType == "video") return;
        _managementPreparing = true; RenderManagementControls(); RenderPreviewControls();
        var generation = _viewGeneration; var closed = false; var busy = false; var allowed = _model.Repository.RecognitionSafety.CorrectFaces;
        SynologyPhotoManualFacesEditor? editor = null; SynologyPhotoRecognitionEdit? frozen = null; SynologyPhotoRecognitionChange? submitted = null;
        var body = new ContentControl { HorizontalContentAlignment = HorizontalAlignment.Stretch };
        var spinner = new ProgressRing { Width = 24, Height = 24, HorizontalAlignment = HorizontalAlignment.Left };
        var message = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var restriction = new TextBlock { Text = _l.Get("PhotosFacesRestricted"), TextWrapping = TextWrapping.Wrap, Visibility = Visible(!allowed) };
        var retry = QueueButton("PhotosRetry"); var reload = QueueButton("PhotosManualReload"); reload.Visibility = Visibility.Collapsed;
        var panel = new StackPanel { MinWidth = 290, Width = Math.Clamp(XamlRoot.Size.Width - 128, 290, 1000), Spacing = 12 };
        foreach (var element in new FrameworkElement[] { spinner, message, restriction, retry, reload, body }) panel.Children.Add(element);
        var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = _l.Get("PhotosManualFaces"),
            PrimaryButtonText = _l.Get("PhotosShareContinue"), CloseButtonText = _l.Get("PhotosCancel"), DefaultButton = ContentDialogButton.Close,
            Content = new ScrollViewer { Content = panel, MaxHeight = Math.Max(240, XamlRoot.Size.Height - 220) } };
        dialog.Resources["ContentDialogMaxWidth"] = 1100d;
        bool Current() => !closed && !_disposed && generation == _viewGeneration;
        void Render()
        {
            if (!Current()) return; spinner.IsActive = busy; spinner.Visibility = Visible(busy); body.IsEnabled = !busy;
            retry.Visibility = Visible(!busy && editor is null); message.Visibility = Visible(message.Text.Length > 0); reload.IsEnabled = !busy;
            dialog.IsPrimaryButtonEnabled = !busy && allowed && editor?.CanSave == true;
        }
        async Task Load(bool discard = false)
        {
            if (busy || !Current()) return; busy = true; message.Text = _l.Get("PhotosLoadingDescription"); Render();
            try
            {
                var photo = await _model.Repository.DetailsAsync(original, _viewCancellation.Token);
                if (!discard && (!photo.IsSameDeletionTarget(original) || photo.AlbumContext != original.AlbumContext)) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
                if (photo.MediaType == "video") throw new SynologyPhotoException(SynologyPhotoFailure.Unavailable);
                var regions = await _model.Repository.PhotoFacesAsync(photo, _viewCancellation.Token);
                var people = await _model.Repository.PeopleAsync(photo.Id.Space, true, _viewCancellation.Token);
                var bytes = await _model.Repository.ThumbnailAsync(photo, true, _viewCancellation.Token);
                var image = await SynologyPhotoFaceImage.DecodeAsync(bytes, _viewCancellation.Token); if (!Current()) return;
                var form = new SynologyPhotoManualFacesEditor(photo, image, regions, people); await form.LoadImageAsync(_viewCancellation.Token); if (!Current()) return;
                original = photo; editor = form; editor.Changed += Render; body.Content = editor; message.Text = ""; reload.Visibility = Visibility.Collapsed;
            }
            catch (Exception error)
            {
                if (Current()) { message.Text = _l.Get(ManagementErrorKey(error)); if (error is SynologyPhotoException { Failure: SynologyPhotoFailure.TargetChanged }) reload.Visibility = Visibility.Visible; }
            }
            finally { busy = false; Render(); }
        }
        retry.Click += async (_, _) => await Load(); reload.Click += async (_, _) => await Load(discard: true);
        dialog.Closed += (_, _) => closed = true;
        dialog.Closing += (_, args) => { if (busy && Current() && _windowVisible && IsLoaded && editor is not null) args.Cancel = true; };
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true; if (busy || !Current() || !allowed || editor?.CanSave != true) return;
            var deferral = args.GetDeferral(); busy = true; Render();
            try
            {
                var edit = await editor.InputAsync(_viewCancellation.Token); await _model.Repository.PrepareRecognitionAsync(edit, _viewCancellation.Token);
                if (Current()) { frozen = edit; args.Cancel = false; }
            }
            catch (Exception error)
            {
                if (Current()) { message.Text = _l.Get(ManagementErrorKey(error)); if (error is SynologyPhotoException { Failure: SynologyPhotoFailure.TargetChanged }) reload.Visibility = Visibility.Visible; }
            }
            finally { busy = false; Render(); deferral.Complete(); }
        };
        try
        {
            SetPhotoDialog(dialog); await _model.Automatic.YieldAsync(); Render(); var showing = ShowPhotoDialogAsync(dialog); await Load(); await showing; if (ReferenceEquals(_dialog, dialog)) SetPhotoDialog(null);
            if (frozen is not null && !_disposed && _windowVisible && generation == _viewGeneration) submitted = await ConfirmRecognitionAsync(frozen);
        }
        finally { closed = true; _managementPreparing = false; if (ReferenceEquals(_dialog, dialog)) SetPhotoDialog(null); RenderManagementControls(); RenderPreviewControls(); }
        if (submitted is not null && !_disposed && generation == _viewGeneration)
        {
            await _model.ApplyRecognitionChangeAsync(submitted);
            if (!_disposed && generation == _viewGeneration && _windowVisible) await ShowRecognitionChangesAsync(submitted.Id);
        }
    }
}
