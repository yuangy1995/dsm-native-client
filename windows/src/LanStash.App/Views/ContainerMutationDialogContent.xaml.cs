using LanStash.App.Features.Containers;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class ContainerMutationDialogContent : UserControl, INasSettingsDialogContent
{
    private readonly IContainerManagerRepository _repository;
    private readonly ContainerMutationViewModel _model = new();
    private bool _disposed, _synchronizing = true;
    private readonly ActionChoice[] _actions;
    public event Action? StateChanged;
    public bool IsBusy => _model.IsBusy;
    public bool CanSave => !_disposed && _model.CanSubmit && RiskAcknowledgement.IsChecked == true;
    public string? PrimaryButtonResourceKey => _model.ActionResourceKey;
    public bool NeedsParentRefresh => _model.NeedsParentRefresh;
    public ContainerMutationDialogContent(IContainerManagerRepository repository)
    {
        _repository = repository; InitializeComponent();
        _actions = Enum.GetValues<ContainerMutationAction>().Select(action => new ActionChoice(action, L.Get(ContainerMutationViewModel.ActionKey(action)))).ToArray();
        ActionPicker.ItemsSource = _actions; ActionPicker.SelectedItem = _actions[0]; ActionPicker.Header = L.Get("ContainerOpsActionLabel");
        SearchBox.PlaceholderText = L.Get("ContainerOpsSearch");
        AutomationProperties.SetName(ActionPicker, L.Get("ContainerOpsActionLabel"));
        AutomationProperties.SetName(SearchBox, L.Get("ContainerOpsSearch"));
        AutomationProperties.SetName(TargetsList, L.Get("ContainerOpsTargets"));
        AutomationProperties.SetName(ResultsList, L.Get("ContainerOpsResults"));
        RiskAcknowledgement.Content = new TextBlock { Text = L.Get("ContainerOpsConfirm"), TextWrapping = TextWrapping.WrapWholeWords };
        TargetsList.ItemsSource = _model.Items; ResultsList.ItemsSource = _model.Results;
        _model.PropertyChanged += (_, _) => Refresh(); _synchronizing = false; Refresh();
    }
    public Task ActivateAsync() => _disposed ? Task.CompletedTask : _model.ActivateAsync(_repository);
    public Task ReloadAsync() => _disposed ? Task.CompletedTask : _model.ReloadAsync();
    public async Task SaveAsync() { ReadSelection(); if (CanSave) await _model.SubmitAsync(); }
    private void Refresh()
    {
        if (_disposed) return; _synchronizing = true;
        LoadingIndicator.IsActive = IsBusy; LoadingIndicator.Visibility = IsBusy ? Visibility.Visible : Visibility.Collapsed;
        ErrorNotice.IsOpen = _model.ErrorMessage is not null; ErrorNotice.Message = _model.ErrorMessage ?? "";
        FeedbackNotice.IsOpen = _model.Feedback is not null; FeedbackNotice.Message = _model.Feedback ?? "";
        FeedbackNotice.Severity = _model.AllSucceeded ? InfoBarSeverity.Success : InfoBarSeverity.Warning;
        ReadOnlyNotice.Text = L.Get("ContainerOpsReadOnly"); ReadOnlyNotice.Visibility = _model.IsReadOnly ? Visibility.Visible : Visibility.Collapsed;
        PendingNotice.Visibility = _model.Pending.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        PendingNotice.Text = L.Format("ContainerOpsPending", string.Join(Environment.NewLine, _model.Pending.Select(item =>
            L.Format("ContainerOpsPendingItem", item.Baseline.Name, L.Get(ContainerMutationViewModel.ActionKey(item.Action))))));
        ActionPicker.IsEnabled = _model.CanSelect; SearchBox.IsEnabled = _model.CanSelect; TargetsList.IsEnabled = _model.CanSelect;
        EmptyNotice.Visibility = _model.CanSelect && _model.Items.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        EmptyNotice.Text = _model.EmptyMessage;
        if (!_model.HasSelection) TargetsList.SelectedItems.Clear();
        SelectionNotice.Visibility = _model.HasSelection ? Visibility.Visible : Visibility.Collapsed;
        SelectionNotice.Text = L.Format("ContainerOpsSelection", _model.SelectionNames);
        RiskNotice.Text = _model.RiskMessage;
        RiskAcknowledgement.IsEnabled = _model.CanConfirm;
        if (!_model.CanSubmit) RiskAcknowledgement.IsChecked = false;
        _synchronizing = false; StateChanged?.Invoke();
    }
    private void ReadSelection() { if (!_disposed && !_synchronizing) _model.SelectTargets(TargetsList.SelectedItems.Cast<ContainerSummary>()); }
    private void Selection_Changed(object sender, SelectionChangedEventArgs e) => ReadSelection();
    private void Action_Changed(object sender, SelectionChangedEventArgs e)
    { if (!_disposed && !_synchronizing && ActionPicker.SelectedItem is ActionChoice choice) _model.SetAction(choice.Action); }
    private void Search_Changed(object sender, TextChangedEventArgs e)
    { if (!_disposed && !_synchronizing) _model.SetQuery(SearchBox.Text); }
    private void Confirm_Changed(object sender, RoutedEventArgs e)
    {
        if (_disposed || _synchronizing) return;
        var confirmed = RiskAcknowledgement.IsChecked == true; ReadSelection(); _model.Confirm(confirmed);
        _synchronizing = true; RiskAcknowledgement.IsChecked = _model.CanSubmit; _synchronizing = false; StateChanged?.Invoke();
    }
    public void Dispose()
    { if (_disposed) return; _disposed = true; _synchronizing = true; _model.Dispose(); TargetsList.ItemsSource = null; ResultsList.ItemsSource = null; StateChanged = null; }
    public sealed record ActionChoice(ContainerMutationAction Action, string Title);
    private static LocalizationService L => LocalizationService.Current;
}
