using LanStash.App.Features.Files.Sharing;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

internal sealed partial class FileShareLinkManagementDialog
{
    private FileShareLinkEditViewModel? _editor;
    private FrameworkElement? _editorContent;
    private readonly HashSet<string> _selectedShareIds = new(StringComparer.Ordinal);
    private Button? _editSelected;
    private Button? _deleteSelected;
    private TextBlock? _selectedCount;

    private FrameworkElement BuildSelectionActions(FileShareLinkManagementViewModel model, LocalizationService localization)
    {
        _selectedShareIds.IntersectWith(model.Links.Select(link => link.Id));
        var panel = new StackPanel { Spacing = 8 };
        _selectedCount = Message("");
        panel.Children.Add(_selectedCount);
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var all = new Button { Content = localization.Get("FileShareSelectAll"), MinHeight = 44 };
        all.Click += (_, _) => { _selectedShareIds.UnionWith(model.Links.Select(link => link.Id)); Render(); };
        var clear = new Button { Content = localization.Get("FileShareClearSelection"), MinHeight = 44 };
        clear.Click += (_, _) => { _selectedShareIds.Clear(); Render(); };
        _editSelected = new Button { Content = localization.Get("FileShareEditAction"), MinHeight = 44 };
        _editSelected.Click += (_, _) => OpenEditor(model.Links.Where(link => _selectedShareIds.Contains(link.Id)).ToArray());
        _deleteSelected = new Button { Content = localization.Get("FileShareLinkManageDeleteAction"), MinHeight = 44 };
        _deleteSelected.Click += (_, _) => model.BeginDeleteMany(model.Links.Where(link => _selectedShareIds.Contains(link.Id)).ToArray());
        actions.Children.Add(all); actions.Children.Add(clear); actions.Children.Add(_editSelected); actions.Children.Add(_deleteSelected);
        panel.Children.Add(actions);
        UpdateSelectionActions();
        return panel;
    }

    private void UpdateSelectionActions()
    {
        if (_selectedCount is not null) _selectedCount.Text = LocalizationService.Current.Format("FileShareBatchCount", _selectedShareIds.Count);
        var enabled = _selectedShareIds.Count > 0 && _model?.IsDeleting == false;
        if (_editSelected is not null) _editSelected.IsEnabled = enabled;
        if (_deleteSelected is not null) _deleteSelected.IsEnabled = enabled;
    }

    private void CloseEditor()
    {
        _editor?.Dispose();
        _editor = null;
        _editorContent = null;
    }

    private void OpenEditor(IReadOnlyList<FileShareLink> links)
    {
        if (_repository is null || _dialog is null || _editor is not null || links.Count == 0) return;
        var model = new FileShareLinkEditViewModel(_repository, _profileId, links);
        _editor = model;
        var localization = LocalizationService.Current;
        var root = new StackPanel { Spacing = 12, MinWidth = 400, MaxWidth = 480 };
        root.Children.Add(Heading(localization.Get("FileShareEditTitle")));
        root.Children.Add(Message(links.Count == 1 ? links[0].Path : localization.Format("FileShareBatchCount", links.Count)));
        var form = new StackPanel { Spacing = 12 };
        var formHost = new ContentControl { Content = form, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        var feedback = new StackPanel { Spacing = 8 };
        AutomationProperties.SetLiveSetting(feedback, AutomationLiveSetting.Polite);
        var save = new Button { Content = localization.Get("FileShareSaveAction"), MinHeight = 44 };
        var review = new Button { Content = localization.Get("FileShareRefreshAction"), MinHeight = 44, Visibility = Visibility.Collapsed };
        var back = new Button { Content = localization.Get("ActionCancel"), MinHeight = 44 };
        var password = new PasswordBox { Header = localization.Get("FileShareNewPasswordLabel"), MinHeight = 44 };
        var validation = new InfoBar { IsClosable = false, Severity = InfoBarSeverity.Error };
        var removePassword = new CheckBox { Content = localization.Get("FileShareRemovePasswordRisk") };
        var audienceRisk = new CheckBox { Content = localization.Get("FileShareAudienceRisk") };
        var membersPanel = new StackPanel { Spacing = 8 };
        var memberStatus = Message("");
        var memberList = new ListView { SelectionMode = ListViewSelectionMode.Multiple, MaxHeight = 180 };
        AutomationProperties.SetName(memberList, localization.Get("FileShareMembersLabel"));
        var selectedMembers = new HashSet<FileSharePrincipal>();
        var synchronizingMembers = false;

        void Update()
        {
            if (!ReferenceEquals(_editor, model)) return;
            save.IsEnabled = model.CanSave;
            validation.IsOpen = model.ValidationMessageKey is not null;
            validation.Message = model.ValidationMessageKey is { } key ? localization.Get(key) : "";
            save.Content = localization.Get(model.HasStarted && !model.IsComplete ? "FileShareContinueAction" : "FileShareSaveAction");
            formHost.IsEnabled = !model.IsBusy && !model.CanReview && !model.IsComplete;
            review.Visibility = model.CanReview ? Visibility.Visible : Visibility.Collapsed;
            back.Content = localization.Get(model.IsBusy ? "ActionCancel" : "FileShareBackAction");
            password.Visibility = model.PasswordIntent == FileShareValueIntent.Replace ? Visibility.Visible : Visibility.Collapsed;
            removePassword.Visibility = model.PasswordIntent == FileShareValueIntent.Clear && links.Any(link => link.HasPassword)
                ? Visibility.Visible : Visibility.Collapsed;
            audienceRisk.Visibility = model.Audience != FileShareAudienceIntent.Keep ? Visibility.Visible : Visibility.Collapsed;
            membersPanel.Visibility = model.Audience == FileShareAudienceIntent.Principals ? Visibility.Visible : Visibility.Collapsed;
        }

        var passwordIntent = ShareChoice(localization.Get("FileShareLinkPasswordLabel"),
            ["FileShareKeep", "FileShareReplacePassword", "FileShareClearPassword"], localization);
        passwordIntent.SelectionChanged += (_, _) =>
        {
            model.PasswordIntent = (FileShareValueIntent)passwordIntent.SelectedIndex;
            removePassword.IsChecked = false; model.PasswordRemovalConfirmed = false; Update();
        };
        password.PasswordChanged += (_, _) => { model.Password = password.Password; Update(); };
        removePassword.Checked += (_, _) => { model.PasswordRemovalConfirmed = true; Update(); };
        removePassword.Unchecked += (_, _) => { model.PasswordRemovalConfirmed = false; Update(); };
        form.Children.Add(passwordIntent);
        form.Children.Add(password);
        form.Children.Add(removePassword);
        AddShareDateControls(form, "FileShareAvailableDate", links.Count == 1 ? links[0].AvailableOn : null,
            localization, (intent, date) => { model.AvailableDateIntent = intent; model.AvailableOn = date; Update(); });
        AddShareDateControls(form, "FileShareLinkExpirationLabel", links.Count == 1 ? links[0].ExpiresOn : null,
            localization, (intent, date) => { model.ExpiryDateIntent = intent; model.ExpiresOn = date; Update(); });

        if (model.SupportsAdvanced)
        {
            var audience = ShareChoice(localization.Get("FileShareAudienceLabel"), model.SupportsMembers
                ? ["FileShareKeep", "FileShareAnyone", "FileShareNamedMembers"]
                : ["FileShareKeep", "FileShareAnyone"], localization);
            audience.SelectionChanged += (_, _) =>
            {
                model.Audience = (FileShareAudienceIntent)audience.SelectedIndex;
                audienceRisk.IsChecked = false; model.AudienceChangeConfirmed = false; Update();
            };
            audienceRisk.Checked += (_, _) => { model.AudienceChangeConfirmed = true; Update(); };
            audienceRisk.Unchecked += (_, _) => { model.AudienceChangeConfirmed = false; Update(); };
            form.Children.Add(audience);
            form.Children.Add(audienceRisk);
            var query = new TextBox { Header = localization.Get("FileShareMemberSearchLabel"), MinHeight = 44 };
            var search = new Button { Content = localization.Get("FileShareFindMembersAction"), MinHeight = 44 };
            search.Click += async (_, _) => await model.LoadMembersAsync(query.Text);
            memberList.SelectionChanged += (_, args) =>
            {
                if (synchronizingMembers) return;
                foreach (var item in args.RemovedItems.OfType<ListViewItem>())
                    if (item.Tag is FileSharePrincipal member) selectedMembers.Remove(member);
                foreach (var item in args.AddedItems.OfType<ListViewItem>())
                    if (item.Tag is FileSharePrincipal member) selectedMembers.Add(member);
                model.SelectedMembers = selectedMembers.ToArray();
                audienceRisk.IsChecked = false; model.AudienceChangeConfirmed = false;
                Update();
            };
            var selectedText = Message("");
            var clearMembers = new Button { Content = localization.Get("FileShareClearMembersAction"), MinHeight = 44 };
            clearMembers.Click += (_, _) =>
            {
                selectedMembers.Clear(); model.SelectedMembers = []; memberList.SelectedItems.Clear();
                selectedText.Text = localization.Format("FileShareSelectedMembers", 0); Update();
            };
            memberList.SelectionChanged += (_, _) => selectedText.Text = localization.Format("FileShareSelectedMembers", selectedMembers.Count);
            membersPanel.Children.Add(query); membersPanel.Children.Add(search); membersPanel.Children.Add(memberStatus);
            membersPanel.Children.Add(memberList); membersPanel.Children.Add(selectedText); membersPanel.Children.Add(clearMembers);
            form.Children.Add(membersPanel);
            IReadOnlyList<FileSharePrincipal>? displayedMembers = null;
            model.PropertyChanged += (_, _) => _dispatcherQueue.TryEnqueue(() =>
            {
                if (!ReferenceEquals(_editor, model)) return;
                search.IsEnabled = !model.IsLoadingMembers;
                memberStatus.Text = localization.Get(model.IsLoadingMembers ? "FileShareMembersLoading" :
                    model.MembersFailed ? "FileShareMembersError" : model.Members.Count == 0 ? "FileShareMembersEmpty" : "FileShareMembersLabel");
                if (!ReferenceEquals(displayedMembers, model.Members))
                {
                    displayedMembers = model.Members;
                    synchronizingMembers = true;
                    memberList.Items.Clear();
                    foreach (var member in model.Members)
                    {
                        var item = new ListViewItem
                        {
                            Tag = member, Content = localization.Format(member.Kind == FileSharePrincipalKind.User
                                ? "FileShareMemberUser" : "FileShareMemberGroup", member.Name), MinHeight = 44,
                        };
                        memberList.Items.Add(item);
                        if (selectedMembers.Contains(member)) memberList.SelectedItems.Add(item);
                    }
                    synchronizingMembers = false;
                }
            });
            var limitToggle = new CheckBox { Content = localization.Get("FileShareChangeAccessLimit") };
            var limit = new NumberBox { Header = localization.Get("FileShareAccessLimitLabel"), Minimum = 0, Maximum = 9999,
                Value = links.Count == 1 ? links[0].Advanced!.MaximumAccesses : 0, SmallChange = 1, IsEnabled = false };
            void LimitChanged()
            {
                limit.IsEnabled = limitToggle.IsChecked == true;
                model.MaximumAccesses = limitToggle.IsChecked == true ?
                    double.IsFinite(limit.Value) && limit.Value == Math.Truncate(limit.Value) ? (int)limit.Value : -1 : null;
                Update();
            }
            limitToggle.Checked += (_, _) => LimitChanged(); limitToggle.Unchecked += (_, _) => LimitChanged();
            limit.ValueChanged += (_, _) => LimitChanged();
            form.Children.Add(limitToggle); form.Children.Add(limit);
            if (model.SupportsFileRequest)
            {
                var changeRequest = new CheckBox { Content = localization.Get("FileShareChangeCollectionInfo") };
                var name = new TextBox { Header = localization.Get("FileShareCollectionName"),
                    Text = links.Count == 1 ? links[0].Advanced!.RequestName : "", IsEnabled = false };
                var message = new TextBox { Header = localization.Get("FileShareCollectionMessage"), AcceptsReturn = true,
                    Text = links.Count == 1 ? links[0].Advanced!.RequestMessage : "", IsEnabled = false, TextWrapping = TextWrapping.Wrap };
                void RequestChanged()
                {
                    name.IsEnabled = message.IsEnabled = changeRequest.IsChecked == true;
                    model.RequestName = changeRequest.IsChecked == true ? name.Text : null;
                    model.RequestMessage = changeRequest.IsChecked == true ? message.Text : null; Update();
                }
                changeRequest.Checked += (_, _) => RequestChanged(); changeRequest.Unchecked += (_, _) => RequestChanged();
                name.TextChanged += (_, _) => RequestChanged(); message.TextChanged += (_, _) => RequestChanged();
                form.Children.Add(changeRequest); form.Children.Add(name); form.Children.Add(message);
            }
        }
        save.Click += async (_, _) => { var saving = model.SaveAsync(); password.Password = ""; Update(); await saving; Update(); };
        review.Click += async (_, _) => { await model.ReviewAsync(); Update(); };
        back.Click += async (_, _) =>
        {
            if (model.IsBusy) { model.Cancel(); return; }
            password.Password = ""; CloseEditor();
            if (_model is { } management) await management.LoadAsync();
            Render();
        };
        model.PropertyChanged += (_, _) => _dispatcherQueue.TryEnqueue(() =>
        {
            if (!ReferenceEquals(_editor, model)) return;
            feedback.Children.Clear();
            if (model.IsBusy) feedback.Children.Add(new ProgressRing { IsActive = true, Width = 28, Height = 28 });
            foreach (var result in model.Results.Where(item => item.Result is not null))
                feedback.Children.Add(Message(localization.Format("FileShareItemOutcome", ShareLinkDisplayName(result.Link.Path),
                    localization.Get(ShareResultKey(result.Result!)))));
            Update();
        });
        root.Children.Add(formHost); root.Children.Add(validation); root.Children.Add(feedback);
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        actions.Children.Add(back); actions.Children.Add(review); actions.Children.Add(save); root.Children.Add(actions);
        _editorContent = new ScrollViewer { Content = root, MaxHeight = 540, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        Update(); Render();
    }

    private static ComboBox ShareChoice(string header, string[] keys, LocalizationService localization)
    {
        var choice = new ComboBox { Header = header, HorizontalAlignment = HorizontalAlignment.Stretch, MinHeight = 44 };
        foreach (var key in keys) choice.Items.Add(new ComboBoxItem { Content = localization.Get(key), MinHeight = 44 });
        choice.SelectedIndex = 0;
        return choice;
    }

    private static void AddShareDateControls(Panel panel, string titleKey, DateOnly? baseline,
        LocalizationService localization, Action<FileShareValueIntent, DateOnly?> changed)
    {
        var intent = ShareChoice(localization.Get(titleKey), ["FileShareKeep", "FileShareSetDate", "FileShareClearDate"], localization);
        var date = new CalendarDatePicker { Visibility = Visibility.Collapsed, HorizontalAlignment = HorizontalAlignment.Stretch,
            Date = baseline is { } value ? new DateTimeOffset(value.ToDateTime(TimeOnly.MinValue)) : null };
        AutomationProperties.SetName(date, localization.Get(titleKey));
        void Update()
        {
            date.Visibility = intent.SelectedIndex == 1 ? Visibility.Visible : Visibility.Collapsed;
            changed((FileShareValueIntent)intent.SelectedIndex, date.Date is { } selected ? DateOnly.FromDateTime(selected.DateTime) : null);
        }
        intent.SelectionChanged += (_, _) => Update(); date.DateChanged += (_, _) => Update();
        panel.Children.Add(intent); panel.Children.Add(date);
    }

    private static string ShareResultKey(MutationResult result) => result.Status switch
    {
        MutationResultStatus.ConfirmedSuccess => "FileShareChangeSaved",
        MutationResultStatus.SubmittedButUnverified or MutationResultStatus.CancellationRequestedAfterSubmission or
            MutationResultStatus.PartialSuccess => "FileShareChangePending",
        MutationResultStatus.PermissionDenied => "FileShareLinkManagePermissionMessage",
        MutationResultStatus.Unsupported => "FileShareLinkManageUnsupportedMessage",
        MutationResultStatus.CancelledBeforeSubmission => "FileShareNotSubmitted",
        _ when result.ErrorCategory == MutationErrorCategory.Conflict => "FileShareLinkManageChangedMessage",
        _ => "FileShareLinkManageFailureMessage",
    };
}
