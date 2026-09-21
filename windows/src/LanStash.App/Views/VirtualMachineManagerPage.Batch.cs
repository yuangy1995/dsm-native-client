using LanStash.App.Features.VirtualMachines;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class VirtualMachineManagerPage
{
    private ContentDialog? _machineBatchDialog;
    private VirtualMachineBatchViewModel? _machineBatchModel;
    private async void BatchPower_Click(object sender, RoutedEventArgs args) => await ShowPowerBatchAsync();

    private Task ShowPowerBatchAsync() => ShowMachineBatchAsync(deletion: false);
    private async void DeleteMachines_Click(object sender, RoutedEventArgs args) => await ShowMachineBatchAsync(deletion: true);
    private async void DeleteImages_Click(object sender, RoutedEventArgs args) => await ShowMachineBatchAsync(deletion: true, images: true);

    private async Task ShowMachineBatchAsync(bool deletion, bool images = false)
    {
        if (_disposed || _machineBatchDialog is not null || _powerDialog is not null || _settingsDialog is not null || _creationDialog is not null ||
            XamlRoot is null || _viewModel.IsLoading || _viewModel.RequiresReconnect || _repository.ProfileId != _viewModel.ActiveProfileId) return;
        using var model = new VirtualMachineBatchViewModel(_repository, deletion, images);
        var l = LocalizationService.Current;
        var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = l.Get(images ? "VmImageDeleteTitle" : deletion ? "VmDeleteTitle" : "VmBatchTitle"),
            CloseButtonText = l.Get("ActionClose"), DefaultButton = ContentDialogButton.Close };
        _machineBatchDialog = dialog; _machineBatchModel = model;
        var renderedSubmitted = false;
        string SummaryText() => l.Format("VmBatchSummary", model.SelectedCount, model.ConfirmedCount, model.FailedCount, model.UnknownCount, model.CancelledCount, model.NotStartedCount);
        void Buttons()
        {
            dialog.PrimaryButtonText = model.HasSubmitted ? string.Empty : l.Get(VirtualMachineBatchViewModel.ActionKey(model.Action));
            dialog.IsPrimaryButtonEnabled = model.CanSubmit;
            dialog.SecondaryButtonText = model.Pending.Count > 0 ? l.Get("VmPowerReview") : string.Empty;
            dialog.IsSecondaryButtonEnabled = model.CanReview;
        }
        void Render()
        {
            if (_disposed || _machineBatchDialog != dialog) return;
            Buttons();
            var panel = new StackPanel { Width = 500, MaxWidth = 500, Spacing = 10 };
            var refresh = new Button { Name = "VmBatchRefresh", Content = l.Get("VmBatchRefresh"), IsEnabled = !model.IsBusy, MinHeight = 40 };
            refresh.Click += async (_, _) => { var load = model.RefreshAsync(); Render(); await load; Render(); };
            panel.Children.Add(refresh);
            if (model.IsBusy)
            {
                panel.Children.Add(new ProgressRing { IsActive = true, Width = 32, Height = 32 });
                var cancel = new Button { Name = "VmBatchCancelButton", Content = l.Get("VmBatchCancel"), MinHeight = 40 };
                cancel.Click += (_, _) => model.Cancel(); panel.Children.Add(cancel);
            }
            if (!model.HasSubmitted)
            {
                if (!deletion)
                {
                var actions = Enum.GetValues<VirtualMachineBatchAction>().Where(value => value is not (VirtualMachineBatchAction.Delete or VirtualMachineBatchAction.DeleteImage)).Select(value => new VmBatchActionChoice(value, l.Get(VirtualMachineBatchViewModel.ActionKey(value)))).ToArray();
                var action = new ComboBox { Name = "VmBatchAction", ItemsSource = actions, DisplayMemberPath = "Label",
                    SelectedIndex = Array.FindIndex(actions, item => item.Action == model.Action), IsEnabled = model.CanEdit };
                AutomationProperties.SetName(action, l.Get("VmBatchChooseAction"));
                action.SelectionChanged += (_, _) => { if (action.SelectedItem is VmBatchActionChoice choice) { model.SetAction(choice.Action); Render(); } };
                panel.Children.Add(action);
                }
                var list = new ListView { Name = "VmBatchSelection", ItemsSource = model.Targets.Where(item => model.IsEligibleState(item) && !model.Pending.Any(pending => pending.Id == item.Id)).ToArray(),
                    DisplayMemberPath = "Name", SelectionMode = ListViewSelectionMode.Multiple, IsEnabled = model.CanEdit, MaxHeight = 180 };
                AutomationProperties.SetName(list, l.Get(images ? "VmImageDeleteChoose" : "VmBatchChooseMachines"));
                foreach (VirtualMachineBatchTarget item in list.Items) if (model.IsSelected(item.Id)) list.SelectedItems.Add(item);
                var count = new TextBlock { Text = l.Format(images ? "VmImageDeleteSelected" : "VmBatchSelected", model.SelectedCount), TextWrapping = TextWrapping.Wrap };
                var confirmationText = l.Get(images ? "VmImageDeleteConfirm" : deletion ? "VmDeleteConfirm" : "VmBatchConfirm");
                var confirm = new CheckBox { Name = "VmBatchConfirmation", Content = new TextBlock { Text = confirmationText, TextWrapping = TextWrapping.Wrap }, IsChecked = model.HasConfirmation, IsEnabled = model.CanConfirm };
                AutomationProperties.SetName(confirm, confirmationText);
                list.SelectionChanged += (_, args) =>
                {
                    foreach (var item in args.RemovedItems.OfType<VirtualMachineBatchTarget>()) model.Select(item.Id, false);
                    foreach (var item in args.AddedItems.OfType<VirtualMachineBatchTarget>()) model.Select(item.Id, true);
                    count.Text = l.Format(images ? "VmImageDeleteSelected" : "VmBatchSelected", model.SelectedCount); confirm.IsChecked = false; confirm.IsEnabled = model.CanConfirm; Buttons();
                };
                var all = new Button { Content = l.Get("VmBatchSelectAll"), IsEnabled = model.CanEdit, MinHeight = 40 };
                all.Click += (_, _) => { model.SelectAll(); list.SelectAll(); count.Text = l.Format(images ? "VmImageDeleteSelected" : "VmBatchSelected", model.SelectedCount); confirm.IsChecked = false; confirm.IsEnabled = model.CanConfirm; Buttons(); };
                confirm.Click += (_, _) => { model.Confirm(confirm.IsChecked == true); Buttons(); };
                panel.Children.Add(all); panel.Children.Add(list); panel.Children.Add(count);
                if (list.Items.Count == 0 && !model.IsBusy && model.MessageKey is null)
                    panel.Children.Add(new TextBlock { Text = l.Get(images ? "VmImageDeleteEmpty" : deletion ? "VmDeleteNoEligible" : "VmBatchNoEligible"), TextWrapping = TextWrapping.Wrap });
                panel.Children.Add(new TextBlock { Text = l.Get(images ? "VmImageDeleteWarning" : deletion ? "VmDeleteWarning" : model.Action switch { VirtualMachineBatchAction.PowerOn => "VmBatchOnHint", VirtualMachineBatchAction.Shutdown => "VmBatchShutdownHint", _ => "VmBatchOffHint" }), TextWrapping = TextWrapping.Wrap });
                panel.Children.Add(confirm);
            }
            if (model.HasSubmitted)
            {
                var summary = new TextBlock { Name = "VmBatchSummary", Text = SummaryText(), TextWrapping = TextWrapping.Wrap };
                AutomationProperties.SetLiveSetting(summary, Microsoft.UI.Xaml.Automation.Peers.AutomationLiveSetting.Polite); panel.Children.Add(summary);
                if (!model.IsBusy)
                    panel.Children.Add(new ScrollViewer { MaxHeight = 240, Content = new TextBlock { Text = string.Join(Environment.NewLine,
                        model.Results.Select(item => l.Format("VmBatchResultLine", item.Target.Name, Status(item.Result)))), TextWrapping = TextWrapping.Wrap } });
            }
            if (model.Pending.Count > 0)
                panel.Children.Add(new TextBlock { Text = l.Format(images ? "VmImageDeletePending" : deletion ? "VmDeletePending" : "VmBatchPending", model.Pending.Count), TextWrapping = TextWrapping.Wrap });
            if (model.Reviews.Count > 0)
                panel.Children.Add(new ScrollViewer { MaxHeight = 120, Content = new TextBlock { Text = string.Join(Environment.NewLine,
                    model.Reviews.Select(item => l.Format("VmBatchReviewLine", item.Target.Name, l.Get(VirtualMachineBatchViewModel.ActionKey(item.Target.Action)), item.Result is null || !item.Result.Submitted ? l.Get("VmBatchUnknown") : Status(item.Result)))), TextWrapping = TextWrapping.Wrap } });
            if (model.MessageKey is { } key) panel.Children.Add(new InfoBar { IsOpen = true, IsClosable = false,
                Severity = key is "VmBatchEmpty" or "VmDeleteNoEligible" ? InfoBarSeverity.Informational : InfoBarSeverity.Warning, Message = l.Get(key) });
            renderedSubmitted = model.HasSubmitted;
            dialog.Content = new ScrollViewer { MaxHeight = 560, Content = panel };
        }
        string Status(MutationResult? result) => l.Get(result is null ? "VmBatchNotStarted" : result.Status == MutationResultStatus.ConfirmedSuccess ? "VmBatchVerified"
            : result.Counts.Unknown > 0 ? "VmBatchUnknown" : result.Status == MutationResultStatus.CancelledBeforeSubmission ? "VmBatchNotSent" : "VmBatchFailed");
        var queued = false;
        void Changed(object? sender, System.ComponentModel.PropertyChangedEventArgs args)
        {
            if (!model.IsBusy || !model.HasSubmitted || queued) return;
            queued = true;
            if (!DispatcherQueue.TryEnqueue(() =>
            {
                queued = false;
                if (_disposed || _machineBatchDialog != dialog) return;
                if (renderedSubmitted != model.HasSubmitted) { Render(); return; }
                // 执行期间只更新进度，保留取消按钮和焦点，不逐项重建窗口。
                Buttons();
                if (dialog.Content is ScrollViewer { Content: StackPanel panel })
                    foreach (var summary in panel.Children.OfType<TextBlock>().Where(item => item.Name == "VmBatchSummary")) summary.Text = SummaryText();
            })) queued = false;
        }
        model.PropertyChanged += Changed;
        dialog.Opened += async (_, _) => { var load = model.RefreshAsync(); Render(); await load; Render(); };
        dialog.PrimaryButtonClick += async (_, args) => { args.Cancel = true; var deferral = args.GetDeferral(); try { var work = model.SubmitAsync(); Render(); await work; Render(); } finally { deferral.Complete(); } };
        dialog.SecondaryButtonClick += async (_, args) => { args.Cancel = true; var deferral = args.GetDeferral(); try { var work = model.ReviewAsync(); Render(); await work; Render(); } finally { deferral.Complete(); } };
        dialog.Closing += (_, _) => model.Dispose();
        Render();
        try { await dialog.ShowAsync(); }
        finally { model.PropertyChanged -= Changed; if (_machineBatchDialog == dialog) { _machineBatchDialog = null; _machineBatchModel = null; } }
        if (!_disposed && model.NeedsParentRefresh && _repository.ProfileId == _viewModel.ActiveProfileId) await RunAsync(_viewModel.RefreshAsync);
    }
    private void CloseMachineBatchDialog() { _machineBatchModel?.Dispose(); _machineBatchDialog?.Hide(); _machineBatchModel = null; _machineBatchDialog = null; }
    private sealed record VmBatchActionChoice(VirtualMachineBatchAction Action, string Label);
}
