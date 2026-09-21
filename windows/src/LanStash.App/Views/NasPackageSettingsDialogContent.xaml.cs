using LanStash.App.Features.NasAdmin;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed record NasPackageSettingsRow(NasPackageSummary Package, string Detail, string Status, string AutomationName);
public sealed partial class NasPackageSettingsDialogContent : UserControl, INasSettingsDialogContent
{
    private readonly INasSettingsRepository _repository;
    private readonly NasPackageManagementViewModel _model = new();
    private bool _disposed, _synchronizing = true;
    private NasPackageSummary[] _displayed = [];
    public event Action? StateChanged;
    public bool CanSave => false;
    public bool IsBusy => _model.IsBusy;
    public string? PrimaryButtonResourceKey => null;
    public NasPackageSettingsDialogContent(INasSettingsRepository repository)
    { _repository = repository; InitializeComponent(); _model.PropertyChanged += (_, _) => Refresh(); _synchronizing = false; }
    public Task ActivateAsync() => _model.ActivateAsync(_repository);
    public Task ReloadAsync() => _model.ReloadAsync();
    public Task SaveAsync() => Task.CompletedTask;
    private void Refresh()
    {
        if (_disposed) return;
        _synchronizing = true;
        LoadingIndicator.IsActive = IsBusy; LoadingIndicator.Visibility = IsBusy ? Visibility.Visible : Visibility.Collapsed;
        ErrorNotice.IsOpen = _model.ErrorMessage is not null; ErrorNotice.Message = _model.ErrorMessage ?? "";
        FeedbackNotice.IsOpen = _model.Feedback is not null; FeedbackNotice.Message = _model.Feedback ?? "";
        FeedbackNotice.Severity = _model.WasSuccessful ? InfoBarSeverity.Success : InfoBarSeverity.Warning;
        PendingNotice.IsOpen = _model.Pending.Count > 0;
        PendingNotice.Message = L.Format("NasPackagePending", string.Join(Environment.NewLine, _model.Pending.Select(item => item.DisplayName)));
        ReadOnlyNotice.Visibility = _model.IsReadOnly ? Visibility.Visible : Visibility.Collapsed;
        SearchInput.IsEnabled = PackageList.IsEnabled = !IsBusy;
        var visible = _model.VisiblePackages;
        if (!_displayed.SequenceEqual(visible))
        {
            _displayed = visible.ToArray();
            PackageList.ItemsSource = _displayed.Select(item =>
            {
                var detail = item.IsUpgradeAvailable ? L.Format("NasPackageVersionUpgrade", item.Version ?? L.Get("UnknownValue")) : item.Version ?? L.Get("UnknownValue");
                var status = L.Get(item.State switch
                {
                    ResourceState.Running => "StatusRunning", ResourceState.Stopped => "StatusStopped", ResourceState.Waiting => "StatusWaiting",
                    ResourceState.Warning => "StatusWarning", ResourceState.Error => "StatusError", _ => "UnknownValue",
                });
                return new NasPackageSettingsRow(item, detail, status, L.Format("NasDetailsRowAutomationName", item.Name, detail + Environment.NewLine + status));
            }).ToArray();
        }
        PackageList.SelectedItem = PackageList.Items.OfType<NasPackageSettingsRow>().FirstOrDefault(row => row.Package.Id == _model.Selected?.Id);
        EmptyNotice.Visibility = !IsBusy && _model.ErrorMessage is null && visible.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        EmptyNotice.Text = L.Get(_model.Packages.Count == 0 ? "NasPackageEmpty" : "NasPackageNoMatches");
        UpgradeNotice.Visibility = _model.Selected?.IsUpgradeAvailable == true ? Visibility.Visible : Visibility.Collapsed;
        StartButton.IsEnabled = _model.CanChoose(NasPackageAction.Start); StopButton.IsEnabled = _model.CanChoose(NasPackageAction.Stop);
        UninstallButton.IsEnabled = _model.CanChoose(NasPackageAction.Uninstall);
        ConfirmationPanel.Visibility = _model.SelectedAction is not null ? Visibility.Visible : Visibility.Collapsed;
        ConfirmationText.Text = _model.SelectedAction is { } action ? L.Format(action switch
        { NasPackageAction.Start => "NasPackageConfirmStart", NasPackageAction.Stop => "NasPackageConfirmStop", _ => "NasPackageConfirmUninstall" }, _model.Selected?.Name ?? "") : "";
        RiskAcknowledgement.IsEnabled = _model.SelectedAction is { } selected && _model.CanChoose(selected);
        if (!_model.CanExecute) RiskAcknowledgement.IsChecked = false;
        ExecuteButton.IsEnabled = _model.CanExecute;
        ExecuteButton.Content = L.Get(_model.SelectedAction switch
        { NasPackageAction.Start => "NasPackageStart.Content", NasPackageAction.Stop => "NasPackageStop.Content", _ => "NasPackageUninstall.Content" });
        _synchronizing = false; StateChanged?.Invoke();
    }
    private void SynchronizeSelection()
    {
        // 提交前读取实际控件状态，不依赖搜索/选择变更事件已经投递。
        _model.SetSearch(SearchInput.Text);
        _model.SelectPackage((PackageList.SelectedItem as NasPackageSettingsRow)?.Package.Id);
    }
    private void Selection_Changed(object sender, SelectionChangedEventArgs e) { if (!_synchronizing) SynchronizeSelection(); }
    private void Search_Changed(object sender, TextChangedEventArgs e) { if (!_synchronizing) _model.SetSearch(SearchInput.Text); }
    private void Start_Click(object sender, RoutedEventArgs e) { SynchronizeSelection(); _model.ChooseAction(NasPackageAction.Start); }
    private void Stop_Click(object sender, RoutedEventArgs e) { SynchronizeSelection(); _model.ChooseAction(NasPackageAction.Stop); }
    private void Uninstall_Click(object sender, RoutedEventArgs e) { SynchronizeSelection(); _model.ChooseAction(NasPackageAction.Uninstall); }
    private void Risk_Changed(object sender, RoutedEventArgs e)
    {
        if (_synchronizing) return;
        var confirmed = RiskAcknowledgement.IsChecked == true; SynchronizeSelection(); _model.ConfirmAction(confirmed);
        _synchronizing = true; RiskAcknowledgement.IsChecked = _model.CanExecute; _synchronizing = false;
    }
    private async void Execute_Click(object sender, RoutedEventArgs e) { SynchronizeSelection(); await _model.ExecuteAsync(); }
    public void Dispose() { if (_disposed) return; _disposed = true; _synchronizing = true; _model.Dispose(); PackageList.ItemsSource = null; _displayed = []; StateChanged = null; }
    private static LocalizationService L => LocalizationService.Current;
}
