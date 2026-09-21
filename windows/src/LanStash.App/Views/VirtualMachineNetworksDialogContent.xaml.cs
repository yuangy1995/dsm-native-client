using LanStash.App.Features.VirtualMachines;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class VirtualMachineNetworksDialogContent : UserControl, IDisposable
{
    private readonly VirtualMachineNetworksViewModel _model;
    private IReadOnlyList<VirtualMachineNetwork>? _displayed;
    private bool _updating, _disposed;
    public event Action? StateChanged;
    public bool CanSubmit => _model.CanSubmit;
    public bool CanReview => _model.CanReview;
    public bool NeedsParentRefresh => _model.NeedsParentRefresh;
    public VirtualMachineNetworksDialogContent(IVirtualMachineManagerRepository repository)
    {
        _model = new(repository); InitializeComponent();
        CancelButton.Content = LocalizationService.Current.Get("ActionCancel");
        _model.PropertyChanged += ModelChanged; Render();
    }
    public async Task ActivateAsync() { await _model.LoadAsync(); Render(); }
    public async Task SubmitAsync() { await _model.SubmitAsync(); Render(); }
    public async Task ReviewAsync() { await _model.ReviewAsync(); Render(); }
    private void ModelChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs args) => DispatcherQueue.TryEnqueue(Render);
    private void Render()
    {
        if (_disposed) return;
        _updating = true;
        if (!ReferenceEquals(_displayed, _model.Networks))
        {
            _displayed = _model.Networks;
            NetworkList.ItemsSource = _displayed.Select(item => new NetworkRow(item)).ToArray();
        }
        ActionSelector.IsEnabled = _model.CanEdit;
        NetworkList.IsEnabled = !_model.IsBusy;
        NewNameBox.Visibility = _model.Action == VirtualMachineNetworkAction.Rename ? Visibility.Visible : Visibility.Collapsed;
        NewNameBox.IsEnabled = _model.CanEdit && _model.SelectedCount == 1;
        NewNameBox.Text = _model.NewName;
        ConfirmBox.IsEnabled = _model.CanConfirm; ConfirmBox.IsChecked = _model.HasConfirmation;
        RiskText.Text = _model.ConfirmationText;
        RiskText.Visibility = _model.SelectedCount > 0 ? Visibility.Visible : Visibility.Collapsed;
        var messageKey = _model.MessageKey ?? _model.ValidationKey;
        Feedback.IsOpen = messageKey is not null;
        Feedback.Message = messageKey is null ? "" : LocalizationService.Current.Get(messageKey);
        Feedback.Severity = messageKey is "VmNetworkLoadFailed" or "VmNetworkSignIn" ? InfoBarSeverity.Error :
            _model.ValidationKey is not null || messageKey is "VmNetworkPending" or "VmNetworkStopped" or "VmNetworkChanged" ? InfoBarSeverity.Warning : InfoBarSeverity.Informational;
        ReloadButton.IsEnabled = _model.CanReload;
        BusyRing.IsActive = _model.IsBusy; LoadingOverlay.Visibility = _model.IsBusy ? Visibility.Visible : Visibility.Collapsed;
        CancelButton.Visibility = _model.IsBusy ? Visibility.Visible : Visibility.Collapsed;
        SummaryText.Text = _model.HasResultSummary ? _model.Summary : "";
        ResultList.ItemsSource = _model.Results;
        _updating = false; StateChanged?.Invoke();
    }
    private void Action_Changed(object sender, SelectionChangedEventArgs e) { if (!_updating) _model.SetAction(ActionSelector.SelectedIndex == 1 ? VirtualMachineNetworkAction.Delete : VirtualMachineNetworkAction.Rename); }
    private void Name_Changed(object sender, TextChangedEventArgs e) { if (!_updating) _model.SetName(NewNameBox.Text); }
    private void Selection_Changed(object sender, SelectionChangedEventArgs e) { if (!_updating) _model.SetSelection(NetworkList.SelectedItems.Cast<NetworkRow>().Select(item => item.Value.Id)); }
    private void Confirmation_Changed(object sender, RoutedEventArgs e) { if (!_updating) _model.SetConfirmed(ConfirmBox.IsChecked == true); }
    private async void Reload_Click(object sender, RoutedEventArgs e) => await ActivateAsync();
    private void Cancel_Click(object sender, RoutedEventArgs e) => _model.Cancel();
    public void Dispose() { if (_disposed) return; _disposed = true; _model.PropertyChanged -= ModelChanged; _model.Dispose(); }
    private sealed record NetworkRow(VirtualMachineNetwork Value)
    {
        public string Name => Value.Name;
        public string Details => LocalizationService.Current.Format("VmNetworkDetails", Value.Interfaces.Count, Value.Guests.Count);
    }
}
