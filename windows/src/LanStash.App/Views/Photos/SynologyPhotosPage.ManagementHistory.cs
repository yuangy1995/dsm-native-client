using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views.Photos;

public sealed partial class SynologyPhotosPage
{
    private async Task ShowPhotoChangesAsync(Guid? selected = null)
    {
        if (_disposed || _dialog is not null) return;
        var generation = _viewGeneration; var closed = false; var loading = false;
        var current = new Dictionary<Guid, SynologyPhotoChange>(); SynologyPhotoChange? editAgain = null;
        var picker = new ComboBox { HorizontalAlignment = HorizontalAlignment.Stretch };
        AutomationProperties.SetName(picker, _l.Get("PhotosChanges"));
        var rows = new StackPanel { Spacing = 12 };
        var message = new TextBlock { TextWrapping = TextWrapping.Wrap, Text = _l.Get("PhotosLoadingDescription") };
        var progress = new ProgressRing { IsActive = true, Width = 24, Height = 24, HorizontalAlignment = HorizontalAlignment.Left };
        var resume = QueueButton("PhotosContinueChanges"); var refresh = QueueButton("PhotosRefresh");
        var cancel = QueueButton("PhotosCancelRemainingChanges"); var reedit = QueueButton("PhotosEditAgain");
        var actions = new StackPanel { Spacing = 8 };
        foreach (var pair in new[] { new[] { resume, refresh }, new[] { reedit, cancel } })
        { var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 }; foreach (var button in pair) row.Children.Add(button); actions.Children.Add(row); }
        var panel = new StackPanel { MinWidth = 290, MaxWidth = 620, Spacing = 12 };
        foreach (var child in new FrameworkElement[] { picker, progress, message, rows, actions }) panel.Children.Add(child);
        var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = _l.Get("PhotosChanges"), CloseButtonText = _l.Get("PhotosClose"),
            Content = new ScrollViewer { Content = panel, MaxHeight = 570, VerticalScrollBarVisibility = ScrollBarVisibility.Auto } };
        SynologyPhotoChange? Selected() => picker.SelectedItem is PhotoChangeChoice choice ? current.GetValueOrDefault(choice.Id) : null;
        bool Active() => !closed && !_disposed && generation == _viewGeneration;
        void Render()
        {
            if (!Active()) return; var change = Selected(); rows.Children.Clear();
            if (change is not null)
            {
                if (change.Kind == SynologyPhotoEditKind.CreateTag)
                    rows.Children.Add(new TextBlock { Text = _l.Format("PhotosChangeTagStatus", change.CreatedTag?.Name is { Length: > 0 } name ? name : _l.Get("PhotosCreateTag"), ChangeStateText(change.TagState)), TextWrapping = TextWrapping.Wrap });
                foreach (var item in change.Items)
                {
                    var row = new StackPanel { Spacing = 4 };
                    row.Children.Add(new TextBlock { Text = item.Original.Filename, TextWrapping = TextWrapping.Wrap, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
                    if (change.Items.Select(value => value.Original.Id.Space).Distinct().Count() > 1)
                        row.Children.Add(new TextBlock { Text = _l.Get(item.Original.Id.Space == SynologyPhotoSpace.Personal ? "PhotosSourcePersonal" : "PhotosSourceShared"), TextWrapping = TextWrapping.Wrap });
                    row.Children.Add(new TextBlock { Text = item.State == SynologyPhotoChangeState.Failed && item.Failure is { } failure
                        ? _l.Get(ManagementErrorKey(new SynologyPhotoException(failure))) : ChangeStateText(item.State), TextWrapping = TextWrapping.Wrap });
                    rows.Children.Add(row);
                }
            }
            message.Text = current.Count == 0 ? _l.Get("PhotosChangesEmpty") : change?.Pending == true ? _l.Get("PhotosChangesPending") : "";
            message.Visibility = Visible(message.Text.Length > 0);
            resume.IsEnabled = !loading && change?.CanContinue == true;
            var hasRemaining = change is not null && (change.Kind == SynologyPhotoEditKind.CreateTag && change.TagState is SynologyPhotoChangeState.Ready or SynologyPhotoChangeState.Failed ||
                change.Items.Any(item => item.State is SynologyPhotoChangeState.Ready or SynologyPhotoChangeState.Failed));
            cancel.IsEnabled = !loading && change is not null && (change.Running || hasRemaining);
            refresh.IsEnabled = !loading;
            reedit.Visibility = Visible(change is { Running: false, Pending: false, CanContinue: false, Completed: false } &&
                hasRemaining);
            reedit.IsEnabled = !loading; picker.IsEnabled = !loading; progress.IsActive = loading; progress.Visibility = Visible(loading);
        }
        async Task Load(bool review = false, bool continueItems = false, bool cancelItems = false)
        {
            if (!Active() || loading) return; loading = true; var choice = Selected(); Render();
            try
            {
                if (choice is not null)
                {
                    SynologyPhotoChange? updated = continueItems ? await _model.Repository.ContinueChangeAsync(choice.Id) :
                        cancelItems ? await _model.Repository.CancelChangeAsync(choice.Id) : review ? await _model.Repository.ReviewChangeAsync(choice.Id) : null;
                    if (updated is not null && Active()) await ApplyPhotoChangeAsync(updated);
                }
                var values = await _model.Repository.ChangesAsync();
                if (!Active()) return;
                current = values.ToDictionary(value => value.Id);
                var choices = values.Select((value, index) => new PhotoChangeChoice(value.Id, _l.Format("PhotosChangeChoice", index + 1, PhotoEditTitle(value.Kind)))).ToArray();
                var id = Selected()?.Id ?? selected;
                if (picker.ItemsSource is not PhotoChangeChoice[] old || !old.SequenceEqual(choices))
                { picker.ItemsSource = choices; picker.SelectedIndex = choices.Length == 0 ? -1 : Math.Max(0, Array.FindIndex(choices, item => item.Id == id)); }
                selected = Selected()?.Id;
            }
            catch (Exception exception)
            {
                if (Active()) { message.Text = _l.Get(ManagementErrorKey(exception)); message.Visibility = Visibility.Visible; }
                return;
            }
            finally { loading = false; if (Active()) { progress.IsActive = false; progress.Visibility = Visibility.Collapsed; picker.IsEnabled = true; refresh.IsEnabled = true; } }
            Render();
        }
        picker.SelectionChanged += (_, _) => { selected = Selected()?.Id; Render(); };
        resume.Click += async (_, _) => await Load(continueItems: true);
        refresh.Click += async (_, _) => await Load(review: true);
        cancel.Click += async (_, _) => await Load(cancelItems: true);
        reedit.Click += async (_, _) =>
        {
            var value = Selected(); if (value is null || loading) return;
            try { editAgain = await _model.Repository.CancelChangeAsync(value.Id); dialog.Hide(); }
            catch (Exception exception) { message.Text = _l.Get(ManagementErrorKey(exception)); message.Visibility = Visibility.Visible; }
        };
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        var nextReview = DateTimeOffset.UtcNow.AddSeconds(15);
        timer.Tick += async (_, _) =>
        {
            if (Selected()?.Running == true) await Load();
            else if (Selected()?.Pending == true && DateTimeOffset.UtcNow >= nextReview)
            { nextReview = DateTimeOffset.UtcNow.AddSeconds(15); await Load(review: true); }
        };
        dialog.Closed += (_, _) => { closed = true; timer.Stop(); };
        try { SetPhotoDialog(dialog); await _model.Automatic.YieldAsync(); var showing = ShowPhotoDialogAsync(dialog); timer.Start(); await Load(); await showing; }
        finally { closed = true; timer.Stop(); if (ReferenceEquals(_dialog, dialog)) SetPhotoDialog(null); }
        if (editAgain is not null && !_disposed && generation == _viewGeneration)
            await ShowPhotoEditAsync(editAgain.Items.Where(item => item.State == SynologyPhotoChangeState.Cancelled).Select(item => item.Original).ToArray(), editAgain.Kind, editAgain.Space);
    }
    private string ChangeStateText(SynologyPhotoChangeState state) => _l.Get(state switch
    {
        SynologyPhotoChangeState.Ready => "PhotosChangeReady", SynologyPhotoChangeState.Submitting => "PhotosChangeSaving",
        SynologyPhotoChangeState.PendingReview => "PhotosChangeWaitingResult", SynologyPhotoChangeState.Completed => "PhotosChangeCompleted",
        SynologyPhotoChangeState.Failed => "PhotosEditFailed", _ => "PhotosChangeCancelled",
    });
}
