using LanStash.App.Features.Containers;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class ContainerNetworkCreateDialogContent : UserControl, INasSettingsDialogContent
{
    private readonly IContainerManagerRepository _repository;
    private readonly ContainerNetworkCreationViewModel _model = new();
    private bool _disposed, _synchronizing = true;
    public event Action? StateChanged;
    public bool IsBusy => _model.IsBusy;
    public bool CanSave => !_disposed && _model.CanSubmit && RiskAcknowledgement.IsChecked == true;
    public string? PrimaryButtonResourceKey => "ContainerCreateAction";
    public bool NeedsParentRefresh => _model.LastResult?.Submitted == true;
    public ContainerNetworkCreateDialogContent(IContainerManagerRepository repository)
    { _repository = repository; InitializeComponent(); _model.PropertyChanged += (_, _) => Refresh(); _synchronizing = false; }
    public Task ActivateAsync() => _model.ActivateAsync(_repository);
    public Task ReloadAsync() => _model.ReloadAsync();
    public async Task SaveAsync() { ReadFields(); if (CanSave) await _model.SubmitAsync(); }
    private void Refresh()
    {
        if (_disposed) return; _synchronizing = true;
        var draft = _model.Draft;
        LoadingIndicator.IsActive = IsBusy; LoadingIndicator.Visibility = IsBusy ? Visibility.Visible : Visibility.Collapsed;
        ErrorNotice.IsOpen = _model.ErrorMessage is not null; ErrorNotice.Message = _model.ErrorMessage ?? "";
        FeedbackNotice.IsOpen = _model.Feedback is not null; FeedbackNotice.Message = _model.Feedback ?? "";
        FeedbackNotice.Severity = _model.WasSuccessful ? InfoBarSeverity.Success : InfoBarSeverity.Warning;
        ReadOnlyNotice.Visibility = _model.IsReadOnly ? Visibility.Visible : Visibility.Collapsed;
        PendingNotice.Visibility = _model.Pending.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        PendingNotice.Text = L.Format("ContainerCreatePending", string.Join(Environment.NewLine, _model.Pending.Select(item => item.Name)));
        NameInput.Text = draft.Name; SubnetInput.Text = draft.Subnet; RangeInput.Text = draft.IpRange; GatewayInput.Text = draft.Gateway;
        Ipv6SubnetInput.Text = draft.Ipv6Subnet; Ipv6RangeInput.Text = draft.Ipv6Range; Ipv6GatewayInput.Text = draft.Ipv6Gateway;
        Ipv4Mode.SelectedIndex = draft.UsesManualIpv4 ? 1 : 0; Ipv6Mode.SelectedIndex = draft.IsIpv6Enabled ? 1 : 0; MasqueradeInput.IsChecked = draft.DisableMasquerade;
        foreach (var control in new Control[] { NameInput, SubnetInput, RangeInput, GatewayInput, Ipv6SubnetInput, Ipv6RangeInput, Ipv6GatewayInput, Ipv4Mode, Ipv6Mode, MasqueradeInput })
            control.IsEnabled = _model.CanEdit;
        Ipv4Fields.Visibility = draft.UsesManualIpv4 ? Visibility.Visible : Visibility.Collapsed;
        Ipv6Fields.Visibility = draft.IsIpv6Enabled ? Visibility.Visible : Visibility.Collapsed;
        AdvancedNotice.Visibility = draft.IsIpv6Enabled || draft.DisableMasquerade ? Visibility.Visible : Visibility.Collapsed;
        ValidationNotice.Visibility = _model.ValidationMessage is not null ? Visibility.Visible : Visibility.Collapsed; ValidationNotice.Text = _model.ValidationMessage ?? "";
        BlockedNameNotice.Visibility = _model.IsNameBlocked ? Visibility.Visible : Visibility.Collapsed;
        RiskAcknowledgement.IsEnabled = _model.CanConfirm;
        if (!_model.CanSubmit) RiskAcknowledgement.IsChecked = false;
        _synchronizing = false; StateChanged?.Invoke();
    }
    private void ReadFields()
    {
        if (_disposed || _synchronizing || !_model.CanEdit) return;
        _model.ChangeDraft(new(NameInput.Text, Ipv4Mode.SelectedIndex == 1, SubnetInput.Text, RangeInput.Text, GatewayInput.Text,
            Ipv6Mode.SelectedIndex == 1, Ipv6SubnetInput.Text, Ipv6RangeInput.Text, Ipv6GatewayInput.Text, MasqueradeInput.IsChecked == true));
    }
    private void Fields_Changed(object sender, TextChangedEventArgs e) => ReadFields();
    private void Modes_Changed(object sender, SelectionChangedEventArgs e) => ReadFields();
    private void Checks_Changed(object sender, RoutedEventArgs e) => ReadFields();
    private void Confirm_Changed(object sender, RoutedEventArgs e)
    {
        if (_disposed || _synchronizing) return;
        var confirmed = RiskAcknowledgement.IsChecked == true; ReadFields(); _model.Confirm(confirmed);
        _synchronizing = true; RiskAcknowledgement.IsChecked = _model.CanSubmit; _synchronizing = false; StateChanged?.Invoke();
    }
    public void Dispose()
    {
        if (_disposed) return; _disposed = true; _synchronizing = true; _model.Dispose();
        NameInput.Text = SubnetInput.Text = RangeInput.Text = GatewayInput.Text = Ipv6SubnetInput.Text = Ipv6RangeInput.Text = Ipv6GatewayInput.Text = "";
        StateChanged = null;
    }
    private static LocalizationService L => LocalizationService.Current;
}
