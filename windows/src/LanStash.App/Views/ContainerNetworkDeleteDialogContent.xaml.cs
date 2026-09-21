using LanStash.App.Features.Containers;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class ContainerNetworkDeleteDialogContent : UserControl, INasSettingsDialogContent
{
    private readonly IContainerManagerRepository _repository;
    private readonly ContainerNetworkDeletionViewModel _model = new();
    private bool _disposed, _synchronizing = true;
    public event Action? StateChanged;
    public bool IsBusy => _model.IsBusy;
    public bool CanSave => !_disposed && _model.CanSubmit && RiskAcknowledgement.IsChecked == true;
    public string? PrimaryButtonResourceKey => "ContainerDeleteAction";
    public bool NeedsParentRefresh => _model.NeedsParentRefresh;
    public ContainerNetworkDeleteDialogContent(IContainerManagerRepository repository)
    { _repository = repository; InitializeComponent(); TargetsList.ItemsSource = _model.Items; _model.PropertyChanged += (_, _) => Refresh(); _synchronizing = false; }
    public Task ActivateAsync() => _model.ActivateAsync(_repository);
    public Task ReloadAsync() => _model.ReloadAsync();
    public async Task SaveAsync() { ReadSelection(); if (CanSave) await _model.SubmitAsync(); }
    private void Refresh()
    {
        if (_disposed) return; _synchronizing = true;
        LoadingIndicator.IsActive = IsBusy; LoadingIndicator.Visibility = IsBusy ? Visibility.Visible : Visibility.Collapsed;
        ErrorNotice.IsOpen = _model.ErrorMessage is not null; ErrorNotice.Message = _model.ErrorMessage ?? "";
        FeedbackNotice.IsOpen = _model.Feedback is not null; FeedbackNotice.Message = _model.Feedback ?? "";
        FeedbackNotice.Severity = _model.LastResult?.Status == MutationResultStatus.ConfirmedSuccess ? InfoBarSeverity.Success : InfoBarSeverity.Warning;
        ReadOnlyNotice.Visibility = _model.IsReadOnly ? Visibility.Visible : Visibility.Collapsed;
        EmptyNotice.Visibility = _model.CanSelect && _model.Items.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        PendingNotice.Visibility = _model.Pending.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        PendingNotice.Text = L.Format("ContainerDeletePending", string.Join(Environment.NewLine, _model.Pending.Select(item => item.Name)));
        TargetsList.IsEnabled = _model.CanSelect;
        if (!_model.HasSelection) TargetsList.SelectedItems.Clear();
        SelectionNotice.Visibility = _model.HasSelection ? Visibility.Visible : Visibility.Collapsed;
        SelectionNotice.Text = L.Format("ContainerDeleteSelection", _model.SelectionNames);
        RiskAcknowledgement.IsEnabled = _model.CanConfirm;
        if (!_model.CanSubmit) RiskAcknowledgement.IsChecked = false;
        _synchronizing = false; StateChanged?.Invoke();
    }
    private void ReadSelection()
    { if (!_disposed && !_synchronizing) _model.SelectTargets(TargetsList.SelectedItems.Cast<ContainerResourceSummary>().ToArray()); }
    private void Selection_Changed(object sender, SelectionChangedEventArgs e) => ReadSelection();
    private void Confirm_Changed(object sender, RoutedEventArgs e)
    {
        if (_disposed || _synchronizing) return;
        var confirmed = RiskAcknowledgement.IsChecked == true; ReadSelection(); _model.Confirm(confirmed);
        _synchronizing = true; RiskAcknowledgement.IsChecked = _model.CanSubmit; _synchronizing = false; StateChanged?.Invoke();
    }
    public void Dispose() { if (_disposed) return; _disposed = true; _synchronizing = true; _model.Dispose(); TargetsList.ItemsSource = null; StateChanged = null; }
    private static LocalizationService L => LocalizationService.Current;
}
