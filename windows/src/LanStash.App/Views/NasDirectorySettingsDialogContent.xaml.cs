using LanStash.App.Features.NasAdmin;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed record NasDirectorySettingsRow(NasDirectoryEntry Entry, string Detail, string Status, string AutomationName);
public sealed partial class NasDirectorySettingsDialogContent : UserControl, INasSettingsDialogContent
{
    private readonly INasSettingsRepository _repository;
    private readonly NasDirectoryManagementViewModel _model = new();
    private bool _disposed, _synchronizing = true;
    private int _editorVersion = -1;
    private NasDirectoryEntry[] _displayed = [], _groups = [];
    public event Action? StateChanged;
    public bool CanSave => !_disposed && _model.IsEditing && _model.CanExecute && RiskAcknowledgement.IsChecked == true;
    public bool IsBusy => _model.IsBusy;
    public NasDirectorySettingsDialogContent(INasSettingsRepository repository)
    { _repository = repository; InitializeComponent(); _model.PropertyChanged += (_, _) => Refresh(); _synchronizing = false; }
    public Task ActivateAsync() => _model.ActivateAsync(_repository);
    public Task ReloadAsync() => _model.ReloadAsync();
    public async Task SaveAsync() { ReadFields(); if (CanSave) await _model.ExecuteAsync(); }
    private void Refresh()
    {
        if (_disposed) return; _synchronizing = true;
        LoadingIndicator.IsActive = IsBusy; LoadingIndicator.Visibility = IsBusy ? Visibility.Visible : Visibility.Collapsed;
        ErrorNotice.IsOpen = _model.ErrorMessage is not null; ErrorNotice.Message = _model.ErrorMessage is { } error ? error + Environment.NewLine + L.Get("NasDirectoryRetry") : "";
        FeedbackNotice.IsOpen = _model.Feedback is not null; FeedbackNotice.Message = _model.Feedback ?? "";
        FeedbackNotice.Severity = _model.WasSuccessful ? InfoBarSeverity.Success : InfoBarSeverity.Warning;
        PendingNotice.IsOpen = _model.Pending.Count > 0 && (_model.Pending.Count > 1 || _model.LastResult?.Counts.Unknown is not > 0);
        PendingNotice.Message = L.Format("NasDirectoryPending", string.Join(Environment.NewLine, _model.Pending.Select(item => item.Name)));
        ReadOnlyNotice.Visibility = _model.IsReadOnly ? Visibility.Visible : Visibility.Collapsed;
        KindChoice.IsEnabled = !IsBusy; KindChoice.SelectedIndex = (int)_model.Kind;
        SearchInput.IsEnabled = EntryList.IsEnabled = !IsBusy && !_model.IsEditing; SearchInput.Text = _model.SearchText;
        var visible = _model.VisibleEntries;
        if (!_displayed.SequenceEqual(visible))
        {
            _displayed = visible.ToArray();
            EntryList.ItemsSource = _displayed.Select(item =>
            {
                var detail = item.Description ?? L.Get("UnknownValue");
                detail = L.Format("NasDirectoryIdentityDetails", detail, item.NumericId is long number ? (object)number : L.Get("UnknownValue"));
                if (item.Kind == NasDirectoryKind.User)
                {
                    detail = L.Format("NasDirectoryUserDetails", detail, item.Email ?? L.Get("UnknownValue"));
                    var memberships = item.Groups is null ? L.Get("UnknownValue") : item.Groups.Count == 0 ? L.Get("NasDirectoryNoGroups") : string.Join(L.Get("NasDirectoryListSeparator"), item.Groups);
                    detail = L.Format("NasDirectoryMembershipDetails", detail, memberships);
                }
                var status = item.Kind == NasDirectoryKind.Group ? L.Get("NasDirectoryGroupLabel") : item.IsExpired switch
                { true => L.Get("NasDirectoryDisabled"), false => L.Get("NasDirectoryEnabled"), _ => L.Get("UnknownValue") };
                if (item.IsCurrentAccount) status = L.Format("NasDirectoryCurrentStatus", status);
                return new NasDirectorySettingsRow(item, detail, status, L.Format("NasDetailsRowAutomationName", item.Name, detail + Environment.NewLine + status));
            }).ToArray();
        }
        EntryList.SelectedItem = EntryList.Items.OfType<NasDirectorySettingsRow>().FirstOrDefault(item => ReferenceEquals(item.Entry, _model.Selected));
        EmptyNotice.Visibility = !IsBusy && _model.ErrorMessage is null && visible.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        EmptyNotice.Text = L.Get(_model.SearchText.Length == 0 ? "NasDirectoryEmpty" : "NasDirectoryNoMatches");
        CreateButton.IsEnabled = _model.CanCreate; EditButton.IsEnabled = _model.CanEdit; DeleteButton.IsEnabled = _model.CanDelete;
        if (!_groups.SequenceEqual(_model.Groups)) { _groups = _model.Groups.ToArray(); GroupChoices.ItemsSource = _groups; }
        if (_editorVersion != _model.EditorVersion)
        {
            _editorVersion = _model.EditorVersion;
            NameInput.Text = _model.Draft.Name; DescriptionInput.Text = _model.Draft.Description;
            EmailInput.Text = _model.Draft.Email ?? ""; ExpiredInput.IsChecked = _model.Draft.IsExpired == true;
            ModifyGroupsInput.IsChecked = false; GroupChoices.SelectedItems.Clear();
            foreach (var group in _groups.Where(group => _model.Draft.Groups?.Contains(group.Name) == true)) GroupChoices.SelectedItems.Add(group);
        }
        PasswordInput.Password = _model.Password ?? ""; PasswordConfirmationInput.Password = _model.PasswordConfirmation ?? "";
        EditorPanel.Visibility = _model.IsEditing ? Visibility.Visible : Visibility.Collapsed;
        UserFields.Visibility = _model.Kind == NasDirectoryKind.User ? Visibility.Visible : Visibility.Collapsed;
        foreach (var control in new Control[] { DescriptionInput, EmailInput, ExpiredInput, PasswordInput, PasswordConfirmationInput, CancelEditButton }) control.IsEnabled = _model.CanChangeDraft;
        CancelEditButton.IsEnabled = !IsBusy; NameInput.IsEnabled = _model.IsNew && _model.CanChangeDraft;
        PasswordNote.Visibility = _model.IsNew ? Visibility.Collapsed : Visibility.Visible;
        ModifyGroupsInput.IsEnabled = _model.CanModifyGroups;
        GroupChoices.Visibility = _model.ModifyGroups ? Visibility.Visible : Visibility.Collapsed;
        GroupChoices.IsEnabled = _model.CanModifyGroups;
        GroupsUnavailableNotice.Visibility = _model.Kind == NasDirectoryKind.User && _model.IsEditing && !_model.CanModifyGroups ? Visibility.Visible : Visibility.Collapsed;
        ConfirmationPanel.Visibility = _model.Operation is null ? Visibility.Collapsed : Visibility.Visible;
        ConfirmationText.Text = L.Format(_model.Operation == NasDirectoryOperationKind.Delete
            ? _model.Kind == NasDirectoryKind.User ? "NasDirectoryConfirmDeleteUser" : "NasDirectoryConfirmDeleteGroup"
            : "NasDirectoryConfirmSave", _model.Operation == NasDirectoryOperationKind.Delete ? _model.Selected?.Name ?? "" : _model.Draft.Name.Trim());
        ValidationNotice.Visibility = _model.IsEditing && _model.CanChangeDraft && !_model.CanConfirm ? Visibility.Visible : Visibility.Collapsed;
        RiskAcknowledgement.IsEnabled = !IsBusy && (_model.CanChangeDraft || _model.CanDelete);
        if (!_model.CanExecute) RiskAcknowledgement.IsChecked = false;
        DeleteConfirmedButton.Visibility = _model.Operation == NasDirectoryOperationKind.Delete ? Visibility.Visible : Visibility.Collapsed;
        DeleteConfirmedButton.IsEnabled = _model.CanExecute;
        _synchronizing = false; StateChanged?.Invoke();
    }
    private void SyncContext()
    {
        if (_disposed) return;
        _model.SetKind(KindChoice.SelectedIndex == 1 ? NasDirectoryKind.Group : NasDirectoryKind.User);
        if (!_model.IsEditing) { _model.SetSearch(SearchInput.Text); _model.SelectEntry((EntryList.SelectedItem as NasDirectorySettingsRow)?.Entry.Name); }
    }
    private void ReadFields()
    {
        if (_synchronizing || _disposed) return; SyncContext(); if (!_model.IsEditing || IsBusy) return;
        var user = _model.Kind == NasDirectoryKind.User;
        _model.SetDraft(new(NameInput.Text, DescriptionInput.Text, user ? EmailInput.Text : null, user ? ExpiredInput.IsChecked == true : null,
            user ? GroupChoices.SelectedItems.OfType<NasDirectoryEntry>().Select(item => item.Name).ToArray() : null),
            user ? PasswordInput.Password : null, user ? PasswordConfirmationInput.Password : null, user && ModifyGroupsInput.IsChecked == true);
    }
    private void Kind_Changed(object sender, SelectionChangedEventArgs e) { if (!_synchronizing) SyncContext(); }
    private void Search_Changed(object sender, TextChangedEventArgs e) { if (!_synchronizing) SyncContext(); }
    private void Entry_Changed(object sender, SelectionChangedEventArgs e) { if (!_synchronizing) SyncContext(); }
    private void Fields_Changed(object sender, TextChangedEventArgs e) => ReadFields();
    private void Checks_Changed(object sender, RoutedEventArgs e) => ReadFields();
    private void Groups_Changed(object sender, SelectionChangedEventArgs e) => ReadFields();
    private void Create_Click(object sender, RoutedEventArgs e) { SyncContext(); _model.BeginCreate(); }
    private void Edit_Click(object sender, RoutedEventArgs e) { SyncContext(); _model.BeginEdit(); }
    private void Delete_Click(object sender, RoutedEventArgs e) { SyncContext(); _model.ChooseDelete(); }
    private void CancelEdit_Click(object sender, RoutedEventArgs e) => _model.CancelEdit();
    private void Risk_Changed(object sender, RoutedEventArgs e)
    {
        if (_synchronizing) return; var confirmed = RiskAcknowledgement.IsChecked == true; ReadFields();
        _model.Confirm(confirmed); _synchronizing = true; RiskAcknowledgement.IsChecked = _model.CanExecute; _synchronizing = false;
    }
    private async void DeleteConfirmed_Click(object sender, RoutedEventArgs e) { SyncContext(); if (_model.Operation == NasDirectoryOperationKind.Delete) await _model.ExecuteAsync(); }
    public void Dispose()
    {
        if (_disposed) return; _disposed = true; _synchronizing = true;
        PasswordInput.Password = ""; PasswordConfirmationInput.Password = ""; _model.Dispose();
        EntryList.ItemsSource = null; GroupChoices.ItemsSource = null; _displayed = []; _groups = []; StateChanged = null;
    }
    private static LocalizationService L => LocalizationService.Current;
}
