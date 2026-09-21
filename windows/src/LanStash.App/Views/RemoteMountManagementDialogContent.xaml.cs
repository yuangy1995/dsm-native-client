using LanStash.App.Features.Files.Locations;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class RemoteMountManagementDialogContent : UserControl, INasSettingsDialogContent
{
    private readonly IFileLocationsRepository _repository;
    private readonly string? _preferredPath;
    private readonly RemoteMountAction _initialAction;
    private readonly RemoteMountManagementViewModel _model = new();
    private bool _disposed, _synchronizing = true;
    public event Action? StateChanged;
    public bool IsBusy => _model.IsBusy;
    public bool CanSave => !_disposed && _model.CanSubmit && RiskAcknowledgement.IsChecked == true;
    public string? PrimaryButtonResourceKey => _model.ActionKey;
    public bool NeedsParentRefresh => _model.NeedsParentRefresh;
    public RemoteMountManagementDialogContent(IFileLocationsRepository repository, string? preferredPath = null, RemoteMountAction action = RemoteMountAction.Create)
    {
        _repository = repository; _preferredPath = preferredPath; _initialAction = action;
        InitializeComponent(); _model.PropertyChanged += Model_Changed; _synchronizing = false; Refresh();
    }
    public Task ActivateAsync() => _model.ActivateAsync(_repository, _preferredPath, _initialAction);
    public Task ReloadAsync() { ClearPassword(); return _model.ReloadAsync(); }
    public async Task SaveAsync()
    {
        ReadFields();
        if (!CanSave) return;
        var password = PasswordInput.Password; ClearPassword();
        await _model.SubmitAsync(password);
        if (!_disposed) BodyScroller.ChangeView(null, 0, null, true);
    }
    private void Model_Changed(object? sender, System.ComponentModel.PropertyChangedEventArgs args) => Refresh();
    private void Refresh()
    {
        if (_disposed) return; _synchronizing = true;
        var draft = _model.Draft;
        LoadingIndicator.IsActive = IsBusy; LoadingIndicator.Visibility = IsBusy ? Visibility.Visible : Visibility.Collapsed;
        ErrorNotice.IsOpen = _model.ErrorMessage is not null; ErrorNotice.Message = _model.ErrorMessage ?? "";
        FeedbackNotice.IsOpen = _model.Feedback is not null; FeedbackNotice.Message = _model.Feedback ?? "";
        FeedbackNotice.Severity = _model.Progress?.Stage == RemoteMountStage.Complete ? InfoBarSeverity.Success : InfoBarSeverity.Warning;
        ReadOnlyNotice.Visibility = _model.IsReadOnly ? Visibility.Visible : Visibility.Collapsed;
        EmptyNotice.Visibility = _model.IsReady && _model.FilteredConnections.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        EmptyNotice.Text = L.Get(_model.Connections.Count == 0 ? "RemoteMountEmpty" : "RemoteMountFilteredEmpty");
        var visibleConnections = _model.FilteredConnections;
        if (ConnectionList.ItemsSource is not IReadOnlyList<RemoteMountConnection> displayed || !displayed.SequenceEqual(visibleConnections))
            ConnectionList.ItemsSource = visibleConnections;
        ConnectionList.SelectedItem = _model.Progress is null ? _model.SelectedConnection : null;
        ConnectionList.IsEnabled = FilterInput.IsEnabled = NewButton.IsEnabled = _model.CanChoose;
        PendingList.ItemsSource = _model.Pending; PendingList.SelectedItem = _model.Pending.FirstOrDefault(item => item.RequestId == _model.Progress?.RequestId);
        PendingList.Visibility = _model.Pending.Count > 0 ? Visibility.Visible : Visibility.Collapsed; PendingList.IsEnabled = _model.CanChoose;
        ReviewButton.Visibility = _model.Progress?.Stage is RemoteMountStage.VerifyingConnection or RemoteMountStage.VerifyingDisconnection ? Visibility.Visible : Visibility.Collapsed;
        ReviewButton.IsEnabled = _model.CanReview;
        ActionInput.Visibility = _model.SelectedConnection is not null ? Visibility.Visible : Visibility.Collapsed;
        ActionInput.SelectedIndex = _model.Action == RemoteMountAction.Disconnect ? 1 : 0;
        ActionInput.IsEnabled = _model.CanChoose && _model.Progress is null;
        ConnectionFields.Visibility = _model.Action == RemoteMountAction.Disconnect ? Visibility.Collapsed : Visibility.Visible;
        ServerInput.Text = draft.Server; RemotePathInput.Text = draft.RemotePath; TargetInput.Text = draft.MountPoint;
        UsernameInput.Text = draft.Username ?? ""; DomainInput.Text = draft.Domain ?? "";
        ProtocolInput.SelectedIndex = draft.Protocol == FileRemoteProtocol.Nfs ? 1 : 0;
        NfsVersionInput.SelectedIndex = draft.NfsVersion == RemoteMountNfsVersion.V4 ? 1 : 0;
        NfsTransportInput.SelectedIndex = draft.NfsTransport == RemoteMountNfsTransport.Udp ? 1 : 0;
        foreach (var control in new Control[] { ServerInput, RemotePathInput, TargetInput, UsernameInput, DomainInput, ProtocolInput, NfsVersionInput, NfsTransportInput }) control.IsEnabled = _model.CanEdit;
        NfsTransportInput.IsEnabled &= draft.NfsVersion != RemoteMountNfsVersion.V4;
        CifsFields.Visibility = draft.Protocol == FileRemoteProtocol.Cifs ? Visibility.Visible : Visibility.Collapsed;
        NfsFields.Visibility = draft.Protocol == FileRemoteProtocol.Nfs ? Visibility.Visible : Visibility.Collapsed;
        PasswordInput.IsEnabled = _model.NeedsPassword;
        if (!_model.NeedsPassword) PasswordInput.Password = "";
        PasswordAgainNotice.Visibility = _model.Progress?.Stage == RemoteMountStage.ReadyToConnect && draft.Protocol == FileRemoteProtocol.Cifs ? Visibility.Visible : Visibility.Collapsed;
        ValidationNotice.Text = _model.ValidationMessage ?? ""; ValidationNotice.Visibility = _model.ValidationMessage is not null ? Visibility.Visible : Visibility.Collapsed;
        RiskNotice.Text = _model.ConfirmationText; RiskAcknowledgement.IsEnabled = _model.CanConfirm;
        RiskNotice.Visibility = draft.MountPoint.Length > 0 || _model.SelectedConnection is not null ? Visibility.Visible : Visibility.Collapsed;
        if (!_model.CanSubmit) RiskAcknowledgement.IsChecked = false;
        _synchronizing = false; StateChanged?.Invoke();
    }
    private void ReadFields()
    {
        if (_disposed || _synchronizing || !_model.CanEdit) return;
        var nfs = ProtocolInput.SelectedIndex == 1;
        _model.ChangeDraft(new(ServerInput.Text, RemotePathInput.Text, TargetInput.Text, nfs ? null : UsernameInput.Text,
            nfs ? null : DomainInput.Text, nfs ? FileRemoteProtocol.Nfs : FileRemoteProtocol.Cifs,
            NfsVersionInput.SelectedIndex == 1 ? RemoteMountNfsVersion.V4 : RemoteMountNfsVersion.V3,
            NfsVersionInput.SelectedIndex == 1 || NfsTransportInput.SelectedIndex != 1 ? RemoteMountNfsTransport.Tcp : RemoteMountNfsTransport.Udp));
    }
    private void Fields_Changed(object sender, TextChangedEventArgs args) => ReadFields();
    private void Modes_Changed(object sender, SelectionChangedEventArgs args) => ReadFields();
    private void Protocol_Changed(object sender, SelectionChangedEventArgs args) { if (_synchronizing) return; ClearPassword(); ReadFields(); }
    private void Password_Changed(object sender, RoutedEventArgs args) { if (!_synchronizing && !_disposed) _model.Confirm(false); }
    private void Filter_Changed(object sender, TextChangedEventArgs args) { if (!_synchronizing) _model.SetFilter(FilterInput.Text); }
    private void Connection_Changed(object sender, SelectionChangedEventArgs args)
    {
        if (_synchronizing || ConnectionList.SelectedItem is not RemoteMountConnection selected || selected == _model.SelectedConnection && _model.Progress is null) return;
        ClearPassword(); _model.SelectConnection(selected);
    }
    private void Pending_Changed(object sender, SelectionChangedEventArgs args)
    {
        if (_synchronizing || PendingList.SelectedItem is not RemoteMountProgress selected || selected == _model.Progress) return;
        ClearPassword(); _model.SelectPending(selected);
    }
    private void Action_Changed(object sender, SelectionChangedEventArgs args) { if (_synchronizing) return; ClearPassword(); _model.SetAction(ActionInput.SelectedIndex == 1 ? RemoteMountAction.Disconnect : RemoteMountAction.Update); }
    private void New_Click(object sender, RoutedEventArgs args) { ClearPassword(); _model.NewConnection(); }
    private async void Review_Click(object sender, RoutedEventArgs args) { ClearPassword(); await _model.ReviewAsync(); }
    private void Confirm_Changed(object sender, RoutedEventArgs args)
    {
        if (_synchronizing || _disposed) return;
        var confirmed = RiskAcknowledgement.IsChecked == true; ReadFields(); _model.Confirm(confirmed);
        _synchronizing = true; RiskAcknowledgement.IsChecked = _model.CanSubmit; _synchronizing = false; StateChanged?.Invoke();
    }
    private void ClearPassword() { var previous = _synchronizing; _synchronizing = true; PasswordInput.Password = ""; _synchronizing = previous; }
    public void Dispose()
    {
        if (_disposed) return; _disposed = true; ClearPassword(); _model.PropertyChanged -= Model_Changed; _model.Dispose(); StateChanged = null;
        _synchronizing = true; ConnectionList.ItemsSource = null; PendingList.ItemsSource = null;
        ServerInput.Text = RemotePathInput.Text = TargetInput.Text = UsernameInput.Text = DomainInput.Text = "";
    }
    private static LocalizationService L => LocalizationService.Current;
}
