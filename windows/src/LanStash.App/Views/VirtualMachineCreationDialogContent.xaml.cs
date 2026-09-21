using System.Globalization;
using LanStash.App.Features.VirtualMachines;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class VirtualMachineCreationDialogContent : UserControl, IDisposable
{
    private readonly IVirtualMachineManagerRepository _repository;
    private readonly VirtualMachineCreationViewModel _model = new();
    private readonly List<DiskEditor> _disks = [];
    private readonly List<NetworkEditor> _networks = [];
    private bool _disposed, _synchronizing = true;
    private long _formVersion = -1;
    public event Action? StateChanged;
    public bool CanSubmit => !_disposed && _model.CanSubmit && RiskAcknowledgement.IsChecked == true;
    public bool CanRefresh => _model.CanRefresh;
    public bool NeedsParentRefresh => _model.NeedsParentRefresh;
    public string PrimaryText => _model.PrimaryText;
    public string RefreshText => _model.RefreshText;
    public VirtualMachineCreationDialogContent(IVirtualMachineManagerRepository repository)
    { _repository = repository; InitializeComponent(); _model.PropertyChanged += (_, _) => Refresh(); _synchronizing = false; Refresh(); }
    public Task ActivateAsync() => _model.ActivateAsync(_repository);
    public Task RefreshAsync() { ReadFields(); return _model.RefreshAsync(); }
    public async Task SubmitAsync() { ReadFields(); if (CanSubmit) await _model.SubmitAsync(); }
    private void Refresh()
    {
        if (_disposed) return; _synchronizing = true;
        if (_formVersion != _model.FormVersion) RebuildForm();
        BusyIndicator.IsActive = _model.IsBusy; BusyIndicator.Visibility = Visible(_model.IsBusy);
        ErrorNotice.Message = _model.ErrorMessage ?? ""; ErrorNotice.IsOpen = _model.ErrorMessage is not null;
        FeedbackNotice.Message = _model.Feedback ?? ""; FeedbackNotice.IsOpen = _model.Feedback is not null;
        FeedbackNotice.Severity = _model.LastResult?.Stage == VirtualMachineCreationStage.Complete ? InfoBarSeverity.Success : InfoBarSeverity.Warning;
        TaskProgress.Visibility = Visible(_model.LastResult?.ProgressPercent is not null); TaskProgress.Value = _model.LastResult?.ProgressPercent ?? 0;
        ReadOnlyNotice.Visibility = Visible(_model.IsReadOnly);
        OperatingSystemInput.IsEnabled = _model.CanEdit && (_model.CanChooseAdvanced || _model.Draft?.Advanced is not null);
        AdvancedUnavailableNotice.Visibility = Visible(!_model.CanChooseAdvanced && !_model.IsBusy);
        AdvancedFields.Visibility = Visible(_model.Draft?.Advanced is not null);
        CreationModeHint.Visibility = Visible(_model.CanChooseAdvanced && _model.Draft?.Advanced is null);
        FirmwareInput.IsEnabled = BootImageInput.IsEnabled = _model.CanEdit && _model.CanChooseAdvanced;
        PowerOnInput.IsEnabled = _model.CanEdit && _model.CanRequestPowerOn;
        PowerUnavailableNotice.Visibility = Visible(!_model.CanRequestPowerOn);
        RecoveryInput.IsEnabled = _model.CanRefresh;
        NameInput.IsEnabled = DescriptionInput.IsEnabled = CpuInput.IsEnabled = MemoryInput.IsEnabled = StorageInput.IsEnabled = StartupInput.IsEnabled = _model.CanEdit;
        foreach (var row in _disks) { row.Source.IsEnabled = _model.CanEdit; row.Size.IsEnabled = _model.CanEdit && (row.Source.SelectedItem as Choice)?.Resource is null; row.Remove.IsEnabled = _model.CanEdit && _disks.Count > 1; }
        foreach (var row in _networks) { row.Source.IsEnabled = row.Mac.IsEnabled = _model.CanEdit; row.Remove.IsEnabled = _model.CanEdit && _networks.Count > 1; }
        AddDiskButton.IsEnabled = _model.CanEdit && _disks.Count < 8; AddNetworkButton.IsEnabled = _model.CanEdit && _networks.Count < 8;
        ValidationNotice.Text = _model.ValidationMessage ?? ""; ValidationNotice.Visibility = Visible(_model.ValidationMessage is not null);
        ConfirmationSummary.Text = _model.Draft is { } summary && !string.IsNullOrWhiteSpace(summary.Settings.Name)
            ? L.Format(summary.PowerOnAfterCreation ? "VmCreatePowerSummary" : "VmCreateSummary", summary.Settings.Name, summary.Storage.Name, summary.Disks.Count, summary.Networks.Count) : "";
        if (_model.Draft?.Advanced is { } advanced) ConfirmationSummary.Text += "\n" + L.Format("VmCreateAdvancedSummary",
            L.Get(advanced.OperatingSystem switch { VirtualMachineOperatingSystem.Windows => "VmCreateWindowsPreset.Content", VirtualMachineOperatingSystem.Linux => "VmCreateLinuxPreset.Content", _ => "VmCreateOtherPreset.Content" }),
            L.Get(advanced.Firmware == VirtualMachineFirmware.Uefi ? "VmCreateUefiFirmware.Content" : "VmCreateLegacyFirmware.Content"), advanced.BootImage?.Name ?? L.Get("VmCreateNoBootImage"));
        RiskAcknowledgement.IsEnabled = _model.CanConfirm; if (!_model.CanSubmit) RiskAcknowledgement.IsChecked = false;
        _synchronizing = false; StateChanged?.Invoke();
    }
    private void RebuildForm()
    {
        _formVersion = _model.FormVersion; var draft = _model.Draft;
        OperatingSystemInput.SelectedIndex = draft?.Advanced is { } selectedAdvanced ? (int)selectedAdvanced.OperatingSystem + 1 : 0;
        FirmwareInput.SelectedIndex = draft?.Advanced?.Firmware == VirtualMachineFirmware.Uefi ? 1 : 0;
        var bootChoices = new List<BootImageChoice> { new(L.Get("VmCreateNoBootImage"), null) };
        bootChoices.AddRange(_model.BootImages.Select(item => new BootImageChoice(item.Name, item)));
        if (draft?.Advanced?.BootImage is { } selectedBoot && !bootChoices.Any(item => item.Image == selectedBoot)) bootChoices.Add(new(L.Format("VmCreateMissingChoice", selectedBoot.Name), selectedBoot));
        BootImageInput.ItemsSource = bootChoices; BootImageInput.SelectedItem = bootChoices.FirstOrDefault(item => item.Image == draft?.Advanced?.BootImage);
        NameInput.Text = draft?.Settings.Name ?? ""; DescriptionInput.Text = draft?.Settings.Description ?? "";
        CpuInput.Text = draft?.Settings.CpuCount.ToString(CultureInfo.CurrentCulture) ?? "";
        MemoryInput.Text = draft?.Settings.MemoryMiB.ToString(CultureInfo.CurrentCulture) ?? "";
        StartupInput.SelectedIndex = draft is null ? 0 : (int)draft.Settings.AutoStart;
        PowerOnInput.IsChecked = draft?.PowerOnAfterCreation == true;
        var storageChoices = Choices(_model.FormStorages, draft?.Storage); StorageInput.ItemsSource = storageChoices;
        StorageInput.SelectedItem = storageChoices.FirstOrDefault(choice => SameResource(choice.Resource, draft?.Storage));
        RecoveryInput.ItemsSource = _model.Recoveries.Select(item => new RecoveryChoice(item.Request.Settings.Name, item)).ToArray();
        RecoveryInput.Visibility = Visible(_model.Recoveries.Count > 0);
        DiskRows.Children.Clear(); NetworkRows.Children.Clear(); _disks.Clear(); _networks.Clear();
        if (draft is null) return;
        foreach (var disk in draft.Disks)
        {
            var index = _disks.Count;
            var source = Picker(Choices(_model.Images, disk.Image, "VmCreateBlankDisk"), disk.Image, L.Format("VmCreateDiskSource", index + 1));
            var size = new TextBox { Header = L.Get("VmCreateDiskSize"), Text = (disk.SizeMiB ?? 20480).ToString(CultureInfo.CurrentCulture) };
            var remove = RemoveButton("VmCreateRemoveDisk", index + 1); var row = new DiskEditor(source, size, remove); _disks.Add(row);
            var panel = new StackPanel { Spacing = 8 }; panel.Children.Add(source); panel.Children.Add(size); panel.Children.Add(remove); DiskRows.Children.Add(panel);
            source.SelectionChanged += Choice_Changed; size.TextChanged += Fields_Changed;
            remove.Click += (_, _) => { ReadFields(); if (_model.CanEdit && _model.Draft is { } current && current.Disks.Count > 1) { _model.ChangeDraft(current with { Disks = current.Disks.Where((_, i) => i != index).ToArray() }); RebuildAfterRowsChange(); } };
        }
        foreach (var nic in draft.Networks)
        {
            var index = _networks.Count;
            var source = Picker(Choices(_model.Networks, nic.Network, "VmCreateDisconnected"), nic.Network, L.Format("VmCreateNetworkChoice", index + 1));
            var mac = new TextBox { Header = L.Get("VmCreateMac"), PlaceholderText = L.Get("VmCreateMacAutomatic"), Text = nic.MacAddress ?? "" };
            var remove = RemoveButton("VmCreateRemoveNetwork", index + 1); _networks.Add(new(source, mac, remove));
            var panel = new StackPanel { Spacing = 8 }; panel.Children.Add(source); panel.Children.Add(mac); panel.Children.Add(remove); NetworkRows.Children.Add(panel);
            source.SelectionChanged += Choice_Changed; mac.TextChanged += Fields_Changed;
            remove.Click += (_, _) => { ReadFields(); if (_model.CanEdit && _model.Draft is { } current && current.Networks.Count > 1) { _model.ChangeDraft(current with { Networks = current.Networks.Where((_, i) => i != index).ToArray() }); RebuildAfterRowsChange(); } };
        }
    }
    private static List<Choice> Choices(IReadOnlyList<VirtualizationResourceSummary> resources, VirtualizationResourceSummary? selected, string? emptyKey = null)
    {
        var choices = new List<Choice>(); if (emptyKey is not null) choices.Add(new(L.Get(emptyKey), null));
        choices.AddRange(resources.Select(item => new Choice(item.Name, item)));
        if (selected is not null && !resources.Any(item => SameResource(item, selected))) choices.Add(new(L.Format("VmCreateMissingChoice", selected.Name), selected));
        return choices;
    }
    private static ComboBox Picker(List<Choice> choices, VirtualizationResourceSummary? selected, string label)
    {
        var picker = new ComboBox { ItemsSource = choices, DisplayMemberPath = nameof(Choice.Name), Header = label, HorizontalAlignment = HorizontalAlignment.Stretch };
        picker.SelectedItem = choices.FirstOrDefault(choice => SameResource(choice.Resource, selected)); AutomationProperties.SetName(picker, label); return picker;
    }
    private static bool SameResource(VirtualizationResourceSummary? left, VirtualizationResourceSummary? right) => left is null || right is null
        ? left is null && right is null : left.Id == right.Id && left.Name == right.Name && left.Kind == right.Kind && left.Type == right.Type;
    private static Button RemoveButton(string label, int number)
    { var button = new Button { Content = L.Get("VmCreateRemove"), MinHeight = 44 }; AutomationProperties.SetName(button, L.Format(label, number)); return button; }
    private void ReadFields()
    {
        if (_disposed || _synchronizing || !_model.CanEdit || _model.Draft is not { } draft || StorageInput.SelectedItem is not Choice { Resource: { } storage }) return;
        int Number(string text) => int.TryParse(text, NumberStyles.None, CultureInfo.CurrentCulture, out var value) ? value : -1;
        var disks = _disks.Select(row => (row.Source.SelectedItem as Choice)?.Resource is { } image ? new VirtualMachineCreationDisk(null, image) : new(Number(row.Size.Text))).ToArray();
        var networks = _networks.Select(row => new VirtualMachineCreationNetwork((row.Source.SelectedItem as Choice)?.Resource, string.IsNullOrWhiteSpace(row.Mac.Text) ? null : row.Mac.Text.Trim())).ToArray();
        var advanced = draft.Advanced;
        if (advanced is not null && _model.AdvancedInventory?.Storages.FirstOrDefault(item => item.Id == storage.Id) is { } advancedStorage)
            advanced = advanced with { Storage = advancedStorage, Firmware = (VirtualMachineFirmware)FirmwareInput.SelectedIndex, BootImage = (BootImageInput.SelectedItem as BootImageChoice)?.Image };
        _model.ChangeDraft(draft with { Storage = storage, Disks = disks, Networks = networks, PowerOnAfterCreation = PowerOnInput.IsChecked == true,
            Settings = new(NameInput.Text, DescriptionInput.Text, Number(CpuInput.Text), Number(MemoryInput.Text), (VirtualMachineAutoStart)StartupInput.SelectedIndex), Advanced = advanced });
    }
    private void RebuildAfterRowsChange() { _synchronizing = true; RebuildForm(); _synchronizing = false; Refresh(); }
    private void AddDisk_Click(object sender, RoutedEventArgs e)
    { ReadFields(); if (_model.CanEdit && _model.Draft is { } draft && draft.Disks.Count < 8) { _model.ChangeDraft(draft with { Disks = draft.Disks.Append(new(20480)).ToArray() }); RebuildAfterRowsChange(); } }
    private void AddNetwork_Click(object sender, RoutedEventArgs e)
    { ReadFields(); if (_model.CanEdit && _model.Draft is { } draft && draft.Networks.Count < 8) { _model.ChangeDraft(draft with { Networks = draft.Networks.Append(new(null)).ToArray() }); RebuildAfterRowsChange(); } }
    private void Fields_Changed(object sender, TextChangedEventArgs e) => ReadFields();
    private void OperatingSystem_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (_disposed || _synchronizing) return;
        ReadFields(); _model.SelectOperatingSystem(OperatingSystemInput.SelectedIndex > 0 ? (VirtualMachineOperatingSystem)(OperatingSystemInput.SelectedIndex - 1) : null);
    }
    private void PowerOn_Changed(object sender, RoutedEventArgs e) => ReadFields();
    private void Choice_Changed(object sender, SelectionChangedEventArgs e) { ReadFields(); if (!_synchronizing) Refresh(); }
    private async void Recovery_Changed(object sender, SelectionChangedEventArgs e)
    { if (!_synchronizing && RecoveryInput.SelectedItem is RecoveryChoice choice) await _model.SelectRecoveryAsync(choice.Recovery); }
    private void Confirm_Changed(object sender, RoutedEventArgs e)
    {
        if (_disposed || _synchronizing) return;
        var confirmed = RiskAcknowledgement.IsChecked == true; ReadFields(); _model.Confirm(confirmed);
        _synchronizing = true; RiskAcknowledgement.IsChecked = _model.CanSubmit; _synchronizing = false; StateChanged?.Invoke();
    }
    public void Dispose()
    { if (_disposed) return; _disposed = true; _synchronizing = true; _model.Dispose(); DiskRows.Children.Clear(); NetworkRows.Children.Clear(); _disks.Clear(); _networks.Clear(); NameInput.Text = DescriptionInput.Text = ""; StateChanged = null; }
    private static Visibility Visible(bool value) => value ? Visibility.Visible : Visibility.Collapsed;
    private sealed record Choice(string Name, VirtualizationResourceSummary? Resource);
    private sealed record BootImageChoice(string Name, VirtualMachineCreationImage? Image);
    private sealed record RecoveryChoice(string Name, VirtualMachineCreationRecovery Recovery);
    private sealed record DiskEditor(ComboBox Source, TextBox Size, Button Remove);
    private sealed record NetworkEditor(ComboBox Source, TextBox Mac, Button Remove);
    private static LocalizationService L => LocalizationService.Current;
}
