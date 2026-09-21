using LanStash.App.Features.VirtualMachines;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class VirtualMachinePowerDialogContent : UserControl, IDisposable
{
    private readonly VirtualMachinePowerViewModel _model = new();
    private readonly IVirtualMachineManagerRepository _repository;
    private readonly VirtualMachineSummary _target;
    private readonly VirtualMachinePowerAction _action;
    private bool _disposed, _synchronizing;
    public event Action? StateChanged;
    public bool CanSubmit => !_disposed && _model.CanSubmit && RiskAcknowledgement.IsChecked == true;
    public bool IsBusy => _model.IsBusy;
    public bool NeedsParentRefresh => _model.NeedsParentRefresh;
    public VirtualMachinePowerDialogContent(IVirtualMachineManagerRepository repository, VirtualMachineSummary target, VirtualMachinePowerAction action)
    { _repository = repository; _target = target; _action = action; InitializeComponent(); _model.PropertyChanged += (_, _) => Refresh(); }
    public Task ActivateAsync() => _model.ActivateAsync(_repository, _target, _action);
    public Task ReloadAsync() => _model.ReloadAsync();
    public Task SubmitAsync() => CanSubmit ? _model.SubmitAsync() : Task.CompletedTask;
    private void Refresh()
    {
        if (_disposed) return; _synchronizing = true;
        TargetName.Text = _model.Target?.Name ?? ""; RiskHint.Text = _model.Hint;
        ReadOnlyNotice.Visibility = _model.IsReadOnly ? Visibility.Visible : Visibility.Collapsed;
        BusyIndicator.IsActive = IsBusy; BusyIndicator.Visibility = IsBusy ? Visibility.Visible : Visibility.Collapsed;
        ErrorNotice.IsOpen = _model.ErrorMessage is not null; ErrorNotice.Message = _model.ErrorMessage ?? "";
        FeedbackNotice.IsOpen = _model.Feedback is not null; FeedbackNotice.Message = _model.Feedback ?? "";
        FeedbackNotice.Severity = _model.LastResult?.Status == MutationResultStatus.ConfirmedSuccess ? InfoBarSeverity.Success : InfoBarSeverity.Warning;
        RiskAcknowledgement.IsEnabled = _model.CanConfirm;
        if (!_model.CanSubmit) RiskAcknowledgement.IsChecked = false;
        _synchronizing = false; StateChanged?.Invoke();
    }
    private void Confirm_Changed(object sender, RoutedEventArgs e)
    { if (!_disposed && !_synchronizing) _model.Confirm(RiskAcknowledgement.IsChecked == true); }
    public void Dispose() { if (_disposed) return; _disposed = true; _model.Dispose(); StateChanged = null; }
}
