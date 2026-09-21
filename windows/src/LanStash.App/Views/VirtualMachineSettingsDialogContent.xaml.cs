using System.Globalization;
using LanStash.App.Features.VirtualMachines;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class VirtualMachineSettingsDialogContent : UserControl, IDisposable
{
    private readonly VirtualMachineSettingsViewModel _model = new();
    private readonly IVirtualMachineManagerRepository _repository;
    private readonly string _id;
    private VirtualMachineSettings? _displayedBaseline;
    private bool _disposed, _synchronizing = true;
    public event Action? StateChanged;
    public bool CanSave => !_disposed && _model.CanSubmit && RiskAcknowledgement.IsChecked == true;
    public bool CanReload => _model.CanReload;
    public bool IsBusy => _model.IsBusy;
    public bool NeedsParentRefresh => _model.NeedsParentRefresh;
    public VirtualMachineSettingsDialogContent(IVirtualMachineManagerRepository repository, string id)
    { _repository = repository; _id = id; InitializeComponent(); _model.PropertyChanged += (_, _) => Refresh(); _synchronizing = false; }
    public Task ActivateAsync() => _model.ActivateAsync(_repository, _id);
    public Task ReloadAsync() => _model.ReloadAsync();
    public async Task SaveAsync() { ReadFields(); if (CanSave) await _model.SubmitAsync(); }
    private void Refresh()
    {
        if (_disposed) return; _synchronizing = true;
        BusyIndicator.IsActive = IsBusy; BusyIndicator.Visibility = IsBusy ? Visibility.Visible : Visibility.Collapsed;
        ErrorNotice.IsOpen = _model.ErrorMessage is not null; ErrorNotice.Message = _model.ErrorMessage ?? "";
        FeedbackNotice.IsOpen = _model.Feedback is not null; FeedbackNotice.Message = _model.Feedback ?? "";
        FeedbackNotice.Severity = _model.LastResult?.Status == MutationResultStatus.ConfirmedSuccess ? InfoBarSeverity.Success : InfoBarSeverity.Warning;
        ReadOnlyNotice.Visibility = _model.IsReadOnly ? Visibility.Visible : Visibility.Collapsed;
        if (!ReferenceEquals(_displayedBaseline, _model.Baseline))
        {
            _displayedBaseline = _model.Baseline; var draft = _model.Draft;
            NameInput.Text = draft?.Name ?? ""; DescriptionInput.Text = draft?.Description ?? "";
            CpuInput.Text = draft?.CpuCount.ToString(CultureInfo.CurrentCulture) ?? ""; MemoryInput.Text = draft?.MemoryMiB.ToString(CultureInfo.CurrentCulture) ?? "";
            StartupInput.SelectedIndex = draft is null ? -1 : (int)draft.AutoStart;
            var priorities = new List<PriorityChoice>
            {
                new(8, LanStash.App.Localization.LocalizationService.Current.Get("VmPriorityLow")),
                new(64, LanStash.App.Localization.LocalizationService.Current.Get("VmPriorityBelow")),
                new(256, LanStash.App.Localization.LocalizationService.Current.Get("VmPriorityNormal")),
                new(512, LanStash.App.Localization.LocalizationService.Current.Get("VmPriorityAbove")),
                new(1024, LanStash.App.Localization.LocalizationService.Current.Get("VmPriorityHigh"))
            };
            if (!priorities.Any(choice => choice.Weight == draft?.CpuWeight))
                priorities.Insert(0, new(draft?.CpuWeight, draft?.CpuWeight is { } weight
                    ? LanStash.App.Localization.LocalizationService.Current.Format("VmPriorityCurrent", weight)
                    : LanStash.App.Localization.LocalizationService.Current.Get("VmPriorityUnknown")));
            PriorityInput.ItemsSource = priorities; PriorityInput.SelectedItem = priorities.First(choice => choice.Weight == draft?.CpuWeight);
        }
        NameInput.IsEnabled = DescriptionInput.IsEnabled = StartupInput.IsEnabled = _model.CanEdit;
        CpuInput.IsEnabled = MemoryInput.IsEnabled = _model.CanEditHardware;
        PriorityInput.IsEnabled = _model.CanEditPriority;
        PriorityUnavailableNotice.Visibility = !_model.PriorityAvailable && !_model.IsReadOnly && _model.Baseline is not null ? Visibility.Visible : Visibility.Collapsed;
        HardwareNotice.Visibility = _model.Baseline?.State == VirtualMachineOperationalState.Running ? Visibility.Visible : Visibility.Collapsed;
        ValidationNotice.Text = _model.ValidationMessage ?? ""; ValidationNotice.Visibility = _model.ValidationMessage is null ? Visibility.Collapsed : Visibility.Visible;
        RiskAcknowledgement.IsEnabled = _model.CanConfirm; if (!_model.CanSubmit) RiskAcknowledgement.IsChecked = false;
        _synchronizing = false; StateChanged?.Invoke();
    }
    private void ReadFields()
    {
        if (_disposed || _synchronizing || !_model.CanEdit) return;
        int Number(string text) => int.TryParse(text, NumberStyles.None, CultureInfo.CurrentCulture, out var number) ? number : -1;
        _model.ChangeDraft(new(NameInput.Text, DescriptionInput.Text, Number(CpuInput.Text), Number(MemoryInput.Text), (VirtualMachineAutoStart)StartupInput.SelectedIndex)
            { CpuWeight = (PriorityInput.SelectedItem as PriorityChoice)?.Weight });
    }
    private void Fields_Changed(object sender, TextChangedEventArgs e) => ReadFields();
    private sealed record PriorityChoice(int? Weight, string Name);
    private void Startup_Changed(object sender, SelectionChangedEventArgs e) => ReadFields();
    private void Confirm_Changed(object sender, RoutedEventArgs e)
    {
        if (_disposed || _synchronizing) return;
        var confirmed = RiskAcknowledgement.IsChecked == true; ReadFields(); _model.Confirm(confirmed);
        _synchronizing = true; RiskAcknowledgement.IsChecked = _model.CanSubmit; _synchronizing = false; StateChanged?.Invoke();
    }
    public void Dispose()
    { if (_disposed) return; _disposed = true; _synchronizing = true; _model.Dispose(); NameInput.Text = DescriptionInput.Text = CpuInput.Text = MemoryInput.Text = ""; StateChanged = null; }
}
