using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views.Photos;

public sealed partial class SynologyPhotosPage
{
    private string RecognitionStateText(SynologyPhotoRecognitionChange value) => value.Pending
        ? value.CompletedCount > 0 ? _l.Format(value.SimilarGroups.Count > 0 ? "PhotosSimilarPartial" : ConceptEdit(value.Kind) ? "PhotosConceptPartial" : "PhotosPeoplePartial", value.CompletedCount, value.TotalCount) : _l.Get("PhotosPeopleProcessing")
        : value.State switch
        {
            SynologyPhotoChangeState.Completed => _l.Get("PhotosRecognitionSaved"), SynologyPhotoChangeState.Cancelled => _l.Get("PhotosShareStopped"),
            _ when value.SimilarGroups.Count > 0 && value.CompletedCount > 0 => _l.Format("PhotosSimilarPartial", value.CompletedCount, value.TotalCount),
            _ when value.Kind == SynologyPhotoRecognitionKind.ManualFaces && value.CompletedCount > 0 => _l.Format(value.CanContinue ? "PhotosManualPartialResume" : "PhotosManualPartial", value.CompletedCount, value.TotalCount),
            _ when value.NeedsInput => _l.Get("PhotosRecognitionInputNeeded"), _ when value.Failure is { } failure => _l.Get(ManagementErrorKey(new SynologyPhotoException(failure))),
            _ => _l.Get("PhotosRecognitionReady"),
        };
    private async Task RefreshRecognitionStatusAsync()
    {
        if (!_model.Repository.SupportsRecognitionManagement) return; var generation = _viewGeneration;
        var values = await _model.Repository.RecognitionChangesAsync();
        foreach (var value in values.Where(value => value.Pending && !value.Running))
        {
            if (_disposed || !_windowVisible || _dialog is not null || generation != _viewGeneration) return;
            var updated = await _model.Repository.ReviewRecognitionAsync(value.Id);
            if (!_disposed && generation == _viewGeneration) await _model.ApplyRecognitionChangeAsync(updated);
        }
        if (_disposed || !_windowVisible || _dialog is not null || generation != _viewGeneration) return;
        values = await _model.Repository.RecognitionChangesAsync(); PhotoRecognitionBar.IsOpen = values.Any(value => value.Pending || value.State is SynologyPhotoChangeState.Ready or SynologyPhotoChangeState.Failed);
        PhotoRecognitionBar.Message = _l.Get(values.Any(value => value.Pending) ? "PhotosPeopleProcessing" : "PhotosRecognitionUnfinished");
    }
    private async Task ShowRecognitionChangesAsync(Guid? selected = null)
    {
        if (_disposed || _dialog is not null || !_model.Repository.SupportsRecognitionManagement) return;
        var generation = _viewGeneration; var closed = false; var busy = false; (SynologyPhotoRecognitionKind Kind, SynologyPhotoCollection Target, IReadOnlyList<SynologyPhoto>? Photos)? editAgain = null;
        SynologyPhoto? manualAgain = null;
        SynologyPhotoRecognitionEdit? similarUndo = null;
        var values = new Dictionary<Guid, SynologyPhotoRecognitionChange>();
        var picker = new ComboBox { HorizontalAlignment = HorizontalAlignment.Stretch }; AutomationProperties.SetName(picker, _l.Get("PhotosRecognitionChanges"));
        var message = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var refresh = QueueButton("PhotosRefresh"); var resume = QueueButton("PhotosShareContinue"); var cancel = QueueButton("PhotosShareStop"); var restart = QueueButton("PhotosShareEditAgain");
        var undo = QueueButton("PhotosSimilarUndo"); var groups = new StackPanel { Spacing = 4 };
        var spinner = new ProgressRing { Width = 24, Height = 24, HorizontalAlignment = HorizontalAlignment.Left };
        var panel = new StackPanel { MinWidth = 290, MaxWidth = 580, Spacing = 12 };
        foreach (var control in new FrameworkElement[] { picker, spinner, message, groups, refresh, resume, restart, cancel, undo }) panel.Children.Add(control);
        var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = _l.Get("PhotosRecognitionChanges"), CloseButtonText = _l.Get("PhotosClose"), Content = new ScrollViewer { Content = panel, MaxHeight = 550 } };
        bool Current() => !closed && !_disposed && generation == _viewGeneration;
        SynologyPhotoRecognitionChange? Selected() => picker.SelectedItem is PhotoChangeChoice choice ? values.GetValueOrDefault(choice.Id) : null;
        void Render()
        {
            if (!Current()) return; var value = Selected(); message.Text = value is null ? _l.Get("PhotosRecognitionEmpty") : RecognitionStateText(value);
            picker.IsEnabled = refresh.IsEnabled = !busy; resume.IsEnabled = !busy && value?.CanContinue == true;
            cancel.IsEnabled = !busy && value is { Running: false } && (value.State is SynologyPhotoChangeState.Ready or SynologyPhotoChangeState.Failed || value.SimilarGroups.Any(step => step.State is SynologyPhotoChangeState.Ready or SynologyPhotoChangeState.Failed));
            undo.Visibility = Visible(value?.CanUndo == true); undo.IsEnabled = !busy && value?.CanUndo == true && _model.Repository.RecognitionSafety.SimilarGroups;
            ToolTipService.SetToolTip(undo, _l.Get(undo.IsEnabled ? "PhotosSimilarUndo" : "PhotosSimilarRestricted"));
            groups.Children.Clear();
            if (value is not null) foreach (var (step, index) in value.SimilarGroups.Select((step, index) => (step, index)))
                groups.Children.Add(new TextBlock { Text = _l.Format("PhotosSimilarStep", index + 1, _l.Get(step.State switch
                { SynologyPhotoChangeState.Completed => "PhotosRecognitionSaved", SynologyPhotoChangeState.Cancelled => "PhotosShareStopped",
                    SynologyPhotoChangeState.PendingReview or SynologyPhotoChangeState.Submitting => "PhotosPeopleProcessing", _ => "PhotosRecognitionReady" })), TextWrapping = TextWrapping.Wrap });
            restart.Visibility = Visible(value?.NeedsInput == true); restart.IsEnabled = cancel.IsEnabled;
            restart.Content = _l.Get(value?.Kind == SynologyPhotoRecognitionKind.ManualFaces ? "PhotosManualEditAgain" : "PhotosShareEditAgain");
            spinner.IsActive = busy; spinner.Visibility = Visible(busy);
        }
        async Task Load(bool review = false, bool proceed = false, bool stop = false)
        {
            if (!Current() || busy) return; var prior = Selected(); busy = true; Render(); string? error = null;
            try
            {
                if (prior is not null && proceed) await _model.Repository.ContinueRecognitionAsync(prior.Id);
                if (prior is not null && stop) await _model.Repository.CancelRecognitionAsync(prior.Id);
                var changes = await _model.Repository.RecognitionChangesAsync();
                if (review) foreach (var value in changes.Where(value => value.Pending && !value.Running)) { if (!Current()) return; await _model.Repository.ReviewRecognitionAsync(value.Id); }
                changes = await _model.Repository.RecognitionChangesAsync(); if (!Current()) return; values = changes.ToDictionary(value => value.Id);
                foreach (var value in changes) { if (!Current()) return; await _model.ApplyRecognitionChangeAsync(value); }
                var id = prior?.Id ?? selected; var entries = changes.Select((value, index) => new PhotoChangeChoice(value.Id, _l.Format("PhotosChangeChoice", index + 1, RecognitionTitle(value.Kind)))).ToArray();
                picker.ItemsSource = entries; picker.SelectedIndex = entries.Length == 0 ? -1 : Math.Max(0, Array.FindIndex(entries, value => value.Id == id));
            }
            catch (Exception failure) { error = _l.Get(ManagementErrorKey(failure)); }
            finally { busy = false; Render(); if (Current() && error is not null) message.Text = error; }
        }
        picker.SelectionChanged += (_, _) => Render(); refresh.Click += async (_, _) => await Load(review: true);
        resume.Click += async (_, _) => await Load(proceed: true); cancel.Click += async (_, _) => await Load(stop: true);
        undo.Click += async (_, _) =>
        {
            if (busy || Selected() is not { CanUndo: true } value) return; busy = true; Render(); string? failure = null;
            try { var edit = await _model.Repository.SimilarUndoAsync(value.Id, _viewCancellation.Token); if (Current()) { similarUndo = edit; dialog.Hide(); } }
            catch (Exception error) { failure = _l.Get(ManagementErrorKey(error)); }
            finally { busy = false; Render(); if (Current() && failure is not null) message.Text = failure; }
        };
        restart.Click += async (_, _) =>
        {
            if (busy || Selected() is not { NeedsInput: true } value) return; busy = true; Render(); string? failure = null;
            try
            {
                if (value.Kind == SynologyPhotoRecognitionKind.ManualFaces)
                {
                    var photo = (await _model.Repository.RecognitionPhotosAsync(value.Id, _viewCancellation.Token)).Single();
                    var cancelled = await _model.Repository.CancelRecognitionAsync(value.Id);
                    if (Current() && cancelled.State == SynologyPhotoChangeState.Cancelled) { manualAgain = photo; dialog.Hide(); }
                    return;
                }
                var people = await _model.Repository.PeopleAsync(value.Space, false, _viewCancellation.Token);
                var target = people.SingleOrDefault(person => person.Person.Id == value.TargetIds.FirstOrDefault())?.Person ?? throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
                var photos = PersonPhotoEdit(value.Kind) ? await _model.Repository.RecognitionPhotosAsync(value.Id, _viewCancellation.Token) : null;
                var stopped = await _model.Repository.CancelRecognitionAsync(value.Id);
                if (Current() && stopped.State == SynologyPhotoChangeState.Cancelled) { editAgain = (value.Kind, target, photos); dialog.Hide(); }
            }
            catch (Exception error) { failure = _l.Get(ManagementErrorKey(error)); }
            finally { busy = false; Render(); if (Current() && failure is not null) message.Text = failure; }
        };
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(15) }; timer.Tick += async (_, _) => { if (values.Values.Any(value => value.Pending)) await Load(review: true); };
        dialog.Closed += (_, _) => { closed = true; timer.Stop(); };
        try { SetPhotoDialog(dialog); await _model.Automatic.YieldAsync(); var showing = ShowPhotoDialogAsync(dialog); timer.Start(); await Load(review: true); await showing; }
        finally { closed = true; timer.Stop(); if (ReferenceEquals(_dialog, dialog)) SetPhotoDialog(null); }
        if (editAgain is { } next && !_disposed && _windowVisible && generation == _viewGeneration) await ShowRecognitionEditAsync(next.Kind, next.Target, next.Photos);
        if (manualAgain is { } manual && !_disposed && _windowVisible && generation == _viewGeneration) await ShowManualFacesAsync(manual);
        if (similarUndo is not null && !_disposed && _windowVisible && generation == _viewGeneration) await SubmitSimilarConfirmationAsync(similarUndo);
    }
}
