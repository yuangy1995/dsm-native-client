using System.ComponentModel;
using LanStash.App.Features.VirtualMachines;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class VirtualMachineImageImportDialogContent : UserControl, IDisposable
{
    private readonly VirtualMachineImageImportViewModel _model;
    private bool _rendering, _ready, _disposed;
    public event Action? StateChanged;
    public bool CanSubmit => _model.CanSubmit && FormMatchesDraft();
    public bool CanRefresh => _model.CanRefresh;
    public bool NeedsParentRefresh => _model.NeedsParentRefresh;
    public VirtualMachineImageImportDialogContent(IVirtualMachineManagerRepository repository)
    {
        _model = new(repository); InitializeComponent(); _ready = true;
        _model.PropertyChanged += ModelChanged; Render();
    }
    public Task ActivateAsync() => _model.RefreshAsync();
    public Task SubmitAsync()
    {
        if (_model.CanEdit && !FormMatchesDraft()) Edit();
        return _model.SubmitAsync();
    }
    public Task RefreshAsync() => _model.RefreshAsync();
    private void ModelChanged(object? sender, PropertyChangedEventArgs e) => Render();
    private void Render()
    {
        if (!_ready || _disposed) return; _rendering = true;
        try
        {
            BusyIndicator.IsActive = _model.IsBusy; BusyIndicator.Visibility = Visible(_model.IsBusy);
            ErrorNotice.Message = _model.Error; ErrorNotice.IsOpen = _model.Error is not null;
            FeedbackNotice.Message = _model.Feedback; FeedbackNotice.IsOpen = _model.Feedback is not null;
            FeedbackNotice.Severity = _model.Result?.Stage == VirtualMachineImageImportStage.Complete ? InfoBarSeverity.Success : InfoBarSeverity.Informational;
            TaskProgress.Visibility = Visible(_model.Result?.ProgressPercent is not null); TaskProgress.Value = _model.Result?.ProgressPercent ?? 0;
            ReadOnlyNotice.Visibility = Visible(_model.IsReadOnly);
            if (!ReferenceEquals(StorageInput.ItemsSource, _model.Storages)) StorageInput.ItemsSource = _model.Storages;
            if (!ReferenceEquals(RecoveryInput.ItemsSource, _model.Recoveries)) RecoveryInput.ItemsSource = _model.Recoveries;
            RecoveryInput.Visibility = Visible(_model.Recoveries.Count > 0); RecoveryInput.IsEnabled = _model.CanRefresh;
            NameInput.IsEnabled = PathInput.IsEnabled = TypeInput.IsEnabled = StorageInput.IsEnabled = _model.CanEdit;
            if (_model.ActiveRequest is { } active)
            {
                NameInput.Text = active.Name; PathInput.Text = active.SourcePath; TypeInput.SelectedIndex = (int)active.Type;
                StorageInput.SelectedItems.Clear(); foreach (var storage in _model.Storages.Where(item => active.Storages.Any(selected => selected.Id == item.Id))) StorageInput.SelectedItems.Add(storage);
            }
            else if (_model.Draft is null) { NameInput.Text = ""; PathInput.Text = ""; StorageInput.SelectedItems.Clear(); }
            ConfirmationSummary.Text = _model.Summary;
            ValidationNotice.Text = _model.Validation; ValidationNotice.Visibility = Visible(_model.Validation is not null);
            RiskAcknowledgement.IsEnabled = _model.CanConfirm; RiskAcknowledgement.IsChecked = _model.IsConfirmed;
            NewButton.Visibility = Visible(_model.CanNew);
        }
        finally { _rendering = false; }
        StateChanged?.Invoke();
    }
    private static Visibility Visible(bool value) => value ? Visibility.Visible : Visibility.Collapsed;
    private void Edit()
    {
        if (_ready && !_rendering) _model.Edit(NameInput.Text, PathInput.Text, (VirtualMachineImageType)TypeInput.SelectedIndex, StorageInput.SelectedItems.OfType<VirtualizationResourceSummary>());
    }
    private void Fields_Changed(object sender, TextChangedEventArgs e) => Edit();
    private void Fields_Changing(TextBox sender, TextBoxBeforeTextChangingEventArgs args)
    { if (_ready && !_rendering) _model.Confirm(false); }
    private bool FormMatchesDraft() => _model.Draft is { } draft && NameInput.Text == draft.Name && PathInput.Text == draft.SourcePath &&
        TypeInput.SelectedIndex == (int)draft.Type && StorageInput.SelectedItems.OfType<VirtualizationResourceSummary>().SequenceEqual(draft.Storages);
    private void Choice_Changed(object sender, SelectionChangedEventArgs e) => Edit();
    private void Confirm_Changed(object sender, RoutedEventArgs e) { if (_ready && !_rendering) _model.Confirm(RiskAcknowledgement.IsChecked == true); }
    private async void Recovery_Changed(object sender, SelectionChangedEventArgs e)
    { if (_ready && !_rendering && RecoveryInput.SelectedItem is VirtualMachineImageImportRequest request) await _model.SelectRecoveryAsync(request); }
    private async void New_Click(object sender, RoutedEventArgs e) => await _model.NewAsync();
    public void Dispose() { if (_disposed) return; _disposed = true; _model.PropertyChanged -= ModelChanged; _model.Dispose(); }
}
