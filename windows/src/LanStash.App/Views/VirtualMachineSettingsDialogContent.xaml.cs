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
    public bool CanSave => !_disposed && _model.CanConfirm;
    public bool CanReload => _model.CanReload;
    public bool IsBusy => _model.IsBusy;
    public bool NeedsParentRefresh => _model.NeedsParentRefresh;
    public VirtualMachineSettingsDialogContent(IVirtualMachineManagerRepository repository, string id)
    { _repository = repository; _id = id; InitializeComponent(); _model.PropertyChanged += (_, _) => Refresh(); _synchronizing = false; }
    public Task ActivateAsync() => _model.ActivateAsync(_repository, _id);
    public Task ReloadAsync() => _model.ReloadAsync();
    public async Task SaveAsync() { ReadFields(); if (CanSave && _model.Confirm(true)) await _model.SubmitAsync(); }
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
            CpuInput.Text = draft?.CpuCount?.ToString(CultureInfo.CurrentCulture) ?? ""; MemoryInput.Text = draft?.MemoryMiB?.ToString(CultureInfo.CurrentCulture) ?? "";
            StartupInput.SelectedIndex = draft?.AutoStart is { } startup ? (int)startup : -1;
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
        var configuration = _model.Baseline?.Configuration;
        var unavailable = LanStash.App.Localization.LocalizationService.Current.Get("VirtualMachineManagerValueUnavailable");
        NameInput.IsEnabled = _model.CanEdit;
        DescriptionInput.IsEnabled = _model.CanEdit && configuration?.Description is not null;
        StartupInput.IsEnabled = _model.CanEdit && configuration?.AutoStart is not null;
        CpuInput.IsEnabled = _model.CanEditHardware && configuration?.CpuCount is not null;
        MemoryInput.IsEnabled = _model.CanEditHardware && configuration?.MemoryMiB is not null;
        DescriptionInput.PlaceholderText = configuration?.Description is null ? unavailable : "";
        StartupInput.PlaceholderText = configuration?.AutoStart is null ? unavailable : "";
        CpuInput.PlaceholderText = configuration?.CpuCount is null ? unavailable : "";
        MemoryInput.PlaceholderText = configuration?.MemoryMiB is null ? unavailable : "";
        PriorityInput.IsEnabled = _model.CanEditPriority;
        PriorityUnavailableNotice.Visibility = !_model.PriorityAvailable && !_model.IsReadOnly && _model.Baseline is not null ? Visibility.Visible : Visibility.Collapsed;
        HardwareNotice.Visibility = _model.Baseline?.State == VirtualMachineOperationalState.Running ? Visibility.Visible : Visibility.Collapsed;
        ValidationNotice.Text = _model.ValidationMessage ?? ""; ValidationNotice.Visibility = _model.ValidationMessage is null ? Visibility.Collapsed : Visibility.Visible;
        _synchronizing = false; StateChanged?.Invoke();
    }
    private void ReadFields()
    {
        if (_disposed || _synchronizing || !_model.CanEdit) return;
        int Number(string text) => int.TryParse(text, NumberStyles.None, CultureInfo.CurrentCulture, out var number) ? number : -1;
        var baseline = _model.Baseline!.Configuration;
        _model.ChangeDraft(new(NameInput.Text, baseline.Description is null ? null : DescriptionInput.Text,
            baseline.CpuCount is null ? null : Number(CpuInput.Text), baseline.MemoryMiB is null ? null : Number(MemoryInput.Text),
            baseline.AutoStart is null ? null : (VirtualMachineAutoStart)StartupInput.SelectedIndex)
            { CpuWeight = (PriorityInput.SelectedItem as PriorityChoice)?.Weight });
    }
    private void Fields_Changed(object sender, TextChangedEventArgs e) => ReadFields();
    private sealed record PriorityChoice(int? Weight, string Name);
    private void Startup_Changed(object sender, SelectionChangedEventArgs e) => ReadFields();
    public void Dispose()
    { if (_disposed) return; _disposed = true; _synchronizing = true; _model.Dispose(); NameInput.Text = DescriptionInput.Text = CpuInput.Text = MemoryInput.Text = ""; StateChanged = null; }
}
