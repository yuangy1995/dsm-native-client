using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views.Photos;

public sealed partial class SynologyPhotosPage
{
    private async void PhotoSharedMembers_Click(object sender, RoutedEventArgs args) => await ShowPhotoSharedMembersAsync();
    private async Task ShowPhotoSharedMembersAsync()
    {
        if (_disposed || _dialog is not null) return;
        var generation = _viewGeneration; var closed = false; var busy = false; var pending = false; var confirming = false; var mode = 0; var id = Guid.NewGuid();
        SynologyPhotoSharedMembers? original = null; var members = new List<SynologyPhotoSharedMember>();
        IReadOnlyList<SynologyPhotoShareRecipient> candidates = [];
        var edits = new Dictionary<SynologyPhotoShareIdentity, SynologyPhotoMemberFolderEdit>();
        SynologyPhotoSharedMember? folderMember = null; SynologyPhotoMemberFolderEdit? folderDraft = null;
        var expanded = new HashSet<long>(); var folderRisk = false;
        var body = new StackPanel { Spacing = 12, MinWidth = 280, MaxWidth = 560 };
        var search = new TextBox { PlaceholderText = _l.Get("PhotosShareFindMembers") };
        AutomationProperties.SetName(search, _l.Get("PhotosShareFindMembers")); AutomationProperties.SetAutomationId(search, "PhotoMemberSearch");
        var rows = new StackPanel { Spacing = 14 }; var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var form = new ContentControl { Content = body, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        var message = new TextBlock { TextWrapping = TextWrapping.Wrap }; var retry = new Button { Content = _l.Get("PhotosRetry") };
        var back = new Button { Content = _l.Get("PhotosMemberBack") }; AutomationProperties.SetAutomationId(back, "PhotoMemberBack");
        var panel = new StackPanel { Spacing = 12 }; panel.Children.Add(form); panel.Children.Add(message); panel.Children.Add(retry); panel.Children.Add(back);
        var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = _l.Get("PhotosSharedMembers"),
            PrimaryButtonText = _l.Get("PhotosSaveChanges"), CloseButtonText = _l.Get("PhotosClose"), IsPrimaryButtonEnabled = false,
            Content = new ScrollViewer { Content = panel, MaxHeight = 560, VerticalScrollBarVisibility = ScrollBarVisibility.Auto } };
        Func<Task>? reload = null;
        bool Current() => !closed && !_disposed && generation == _viewGeneration;
        bool Changed() => original is not null && (edits.Values.Any(x => x.CanSave) || original.Members.Count != members.Count || original.Members.Any(x => !members.Contains(x)));
        TextBlock Label(string text) => new() { Text = text, TextWrapping = TextWrapping.Wrap };
        Button Button(string key, string automation) { var value = new Button { Content = _l.Get(key) }; AutomationProperties.SetAutomationId(value, automation); return value; }
        void State()
        {
            if (!Current()) return;
            form.Visibility = Visible(!confirming); form.IsEnabled = !busy && !pending;
            dialog.Title = mode == 2 && folderMember is not null ? _l.Format("PhotosMemberFoldersTitle", folderMember.Recipient.Name) : _l.Get(mode == 1 ? "PhotosMemberAdd" : "PhotosSharedMembers");
            dialog.PrimaryButtonText = _l.Get(mode == 2 ? "PhotosMemberFoldersDone" : confirming ? "PhotosSharedConfirm" : "PhotosSaveChanges");
            dialog.IsPrimaryButtonEnabled = !busy && !pending && (mode == 2 ? folderDraft is not null : mode == 0 && original?.Enabled == true && Changed() && _model.Repository.SettingsSafety.SharedMembers);
            back.Visibility = Visible((mode != 0 || confirming) && !busy); retry.Visibility = Visible(reload is not null && !busy && !confirming);
            message.Visibility = Visible(message.Text.Length > 0);
        }
        void Root()
        {
            body.Children.Clear(); body.Children.Add(search); body.Children.Add(actions); body.Children.Add(rows); actions.Children.Clear(); rows.Children.Clear();
        }
        void MainRows()
        {
            if (!Current() || mode != 0) return; rows.Children.Clear();
            foreach (var member in members.Where(x => x.Recipient.Name.Contains(search.Text, StringComparison.CurrentCultureIgnoreCase)))
            {
                var row = new StackPanel { Spacing = 6 }; row.Children.Add(Label(member.Recipient.Name));
                var role = new ComboBox { HorizontalAlignment = HorizontalAlignment.Stretch, IsEnabled = member.Editable && original?.Enabled == true };
                role.Items.Add(new ComboBoxItem { Content = _l.Get("PhotosMemberEntry"), Tag = "entry" }); role.Items.Add(new ComboBoxItem { Content = _l.Get("PhotosMemberManagement"), Tag = "management" });
                if (member.Role is not ("entry" or "management")) role.Items.Add(new ComboBoxItem { Content = _l.Get("PhotosShareRoleOther"), Tag = member.Role });
                role.SelectedItem = role.Items.Cast<ComboBoxItem>().Single(x => Equals(x.Tag, member.Role));
                AutomationProperties.SetName(role, _l.Format("PhotosShareMemberRole", member.Recipient.Name)); AutomationProperties.SetAutomationId(role, "PhotoMemberRole-" + member.Id.Type + "-" + member.Id.Value);
                role.SelectionChanged += async (_, _) =>
                {
                    if (busy || pending || role.SelectedItem is not ComboBoxItem { Tag: string selected } || selected == member.Role) return;
                    var current = members.Single(x => x.Id == member.Id); var target = current.ChangingRole(selected);
                    if (selected == "entry") await Folders(target);
                    else { members[members.FindIndex(x => x.Id == member.Id)] = target; edits.Remove(member.Id); MainRows(); State(); }
                };
                row.Children.Add(role);
                var controls = new StackPanel { Spacing = 8 };
                var backup = new ToggleSwitch { Header = _l.Get("PhotosMemberBackup"), IsOn = member.AutoBackup, IsEnabled = member.Editable && member.Role == "entry" && original?.Enabled == true,
                    OnContent = _l.Get("PhotosAutomaticOn"), OffContent = _l.Get("PhotosAutomaticOff") };
                AutomationProperties.SetName(backup, _l.Format("PhotosMemberBackupFor", member.Recipient.Name)); AutomationProperties.SetAutomationId(backup, "PhotoMemberBackup-" + member.Id.Type + "-" + member.Id.Value);
                backup.Toggled += (_, _) => { var index = members.FindIndex(x => x.Id == member.Id); if (index >= 0 && !busy && !pending) { members[index] = members[index] with { AutoBackup = backup.IsOn }; State(); } };
                controls.Children.Add(backup);
                var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
                var folders = Button("PhotosMemberFolders", "PhotoMemberFolders-" + member.Id.Type + "-" + member.Id.Value); folders.IsEnabled = member.Editable && member.Role == "entry" && original?.Enabled == true;
                folders.Click += async (_, _) => await Folders(members.Single(x => x.Id == member.Id)); buttons.Children.Add(folders);
                var remove = Button("PhotosShareRemoveMember", "PhotoMemberRemove-" + member.Id.Type + "-" + member.Id.Value); remove.IsEnabled = member.Editable && original?.Enabled == true;
                AutomationProperties.SetName(remove, _l.Format("PhotosShareRemoveNamedMember", member.Recipient.Name));
                remove.Click += (_, _) => { members.RemoveAll(x => x.Id == member.Id); edits.Remove(member.Id); MainRows(); State(); }; buttons.Children.Add(remove);
                controls.Children.Add(buttons); row.Children.Add(controls); if (member.Protected) row.Children.Add(Label(_l.Get("PhotosMemberProtected"))); rows.Children.Add(row);
            }
            if (rows.Children.Count == 0) rows.Children.Add(Label(_l.Get(search.Text.Length > 0 ? "PhotosShareNoMatches" : "PhotosMemberEmpty")));
        }
        void Main()
        {
            mode = 0; confirming = false; folderMember = null; folderDraft = null; folderRisk = false; reload = null; search.Text = ""; search.PlaceholderText = _l.Get("PhotosShareFindMembers"); AutomationProperties.SetName(search, _l.Get("PhotosShareFindMembers")); Root();
            var add = Button("PhotosMemberAdd", "PhotoMemberAdd"); add.IsEnabled = original?.Enabled == true; add.Click += async (_, _) => await Candidates(); actions.Children.Add(add);
            var bulk = new Button { Content = _l.Get("PhotosMemberBackup") }; var menu = new MenuFlyout();
            foreach (var on in new[] { true, false })
            {
                var item = new MenuFlyoutItem { Text = _l.Get(on ? "PhotosMemberBackupAllOn" : "PhotosMemberBackupAllOff") };
                item.Click += (_, _) => { for (var i = 0; i < members.Count; i++) if (members[i].Editable && members[i].Role == "entry") members[i] = members[i] with { AutoBackup = on }; MainRows(); State(); }; menu.Items.Add(item);
            }
            bulk.Flyout = menu; bulk.IsEnabled = original?.Enabled == true; actions.Children.Add(bulk);
            MainRows();
            if (original?.Enabled == false) rows.Children.Add(Label(_l.Get("PhotosSharedIsDisabled")));
            if (!_model.Repository.SettingsSafety.SharedMembers) rows.Children.Add(Label(_l.Get("PhotosMemberUseWeb")));
            State();
        }
        void CandidateRows()
        {
            rows.Children.Clear();
            foreach (var candidate in candidates.Where(x => !members.Any(y => y.Id == x.Id) && !(x.Id.Type == "group" && x.Name == "administrators") && x.Name.Contains(search.Text, StringComparison.CurrentCultureIgnoreCase)))
            {
                var item = new Button { Content = candidate.Name, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Left };
                AutomationProperties.SetAutomationId(item, "PhotoMemberCandidate-" + candidate.Id.Type + "-" + candidate.Id.Value);
                item.Click += async (_, _) => await Folders(new(candidate, "entry", false)); rows.Children.Add(item);
            }
            if (rows.Children.Count == 0) rows.Children.Add(Label(_l.Get("PhotosShareNoMatches")));
        }
        async Task Candidates()
        {
            if (!Current() || busy || pending) return; mode = 1; busy = true; reload = null; search.Text = ""; Root(); message.Text = _l.Get("PhotosLoadingDescription"); State();
            try { var values = await _model.Repository.SharedMemberCandidatesAsync(_viewCancellation.Token); if (!Current()) return; candidates = values; CandidateRows(); message.Text = ""; }
            catch (Exception error) { if (Current()) { message.Text = _l.Get(PreferenceErrorKey(error)); reload = Candidates; } }
            finally { busy = false; State(); }
        }
        void FolderRows()
        {
            if (!Current() || mode != 2 || folderDraft is null) return; rows.Children.Clear(); var draft = folderDraft;
            void Add(SynologyPhotoMemberFolder folder)
            {
                var row = new StackPanel { Spacing = 6, Margin = new Thickness(folder.Depth == 1 ? 16 : 0, 0, 0, 0) };
                if (folder.Depth == 0)
                {
                    var expand = new Button { Content = folder.Name, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Left };
                    AutomationProperties.SetAutomationId(expand, "PhotoMemberExpand-" + folder.Id); AutomationProperties.SetName(expand, _l.Format(expanded.Contains(folder.Id) ? "PhotosMemberCollapseFolder" : "PhotosMemberExpandFolder", folder.Name));
                    expand.Click += (_, _) => { if (!expanded.Add(folder.Id)) expanded.Remove(folder.Id); FolderRows(); }; row.Children.Add(expand);
                }
                else row.Children.Add(Label(folder.Name));
                var role = new ComboBox { HorizontalAlignment = HorizontalAlignment.Stretch, IsEnabled = draft.CanEdit(folder) };
                role.Items.Add(new ComboBoxItem { Content = _l.Get("PhotosMemberNoDirectAccess"), Tag = -1 });
                foreach (var value in Enum.GetValues<SynologyPhotoFolderMemberRole>()) role.Items.Add(new ComboBoxItem { Content = _l.Get(MemberFolderRoleKey(value)), Tag = (int)value });
                var level = SynologyPhotoMemberFolder.Level(draft.Expected(folder));
                if (!folder.Known) { role.Items.Add(new ComboBoxItem { Content = _l.Get("PhotosShareRoleOther"), Tag = -2 }); level = -2; }
                role.SelectedItem = role.Items.Cast<ComboBoxItem>().Single(x => Equals(x.Tag, level));
                AutomationProperties.SetName(role, _l.Format("PhotosShareMemberRole", folder.Name)); AutomationProperties.SetAutomationId(role, "PhotoMemberFolderRole-" + folder.Id);
                role.SelectionChanged += (_, _) =>
                {
                    if (busy || pending || folderDraft is null || role.SelectedItem is not ComboBoxItem { Tag: int value }) return;
                    var changes = (folderDraft.Changes ?? []).Where(x => x.FolderId != folder.Id && !(folder.Depth == 0 && value < 0 && folder.Privacy == "private" && folderDraft.Original.Any(f => f.Id == x.FolderId && f.ParentId == folder.Id))).ToList();
                    changes.Add(new(folder.Id, value < 0 ? null : (SynologyPhotoFolderMemberRole)value)); folderDraft = folderDraft with { Changes = changes };
                    folderRisk |= folder.Depth == 0 && value < 0 && folder.Privacy == "private" && folder.DirectRole is not null;
                    message.Text = folderRisk ? _l.Get("PhotosMemberChildrenWarning") : ""; FolderRows(); State();
                };
                row.Children.Add(role);
                if (folder.PublicLevel >= 0) row.Children.Add(Label(_l.Format("PhotosMemberPublicAccess", _l.Get(MemberFolderRoleKey((SynologyPhotoFolderMemberRole)folder.PublicLevel)))));
                else if (!draft.CanEdit(folder) && folder.Known) row.Children.Add(Label(_l.Get("PhotosMemberParentRequired")));
                rows.Children.Add(row);
            }
            foreach (var parent in draft.Original.Where(x => x.Depth == 0))
            {
                var children = draft.Original.Where(x => x.ParentId == parent.Id).ToArray(); var matches = parent.Name.Contains(search.Text, StringComparison.CurrentCultureIgnoreCase);
                if (!matches && !children.Any(x => x.Name.Contains(search.Text, StringComparison.CurrentCultureIgnoreCase))) continue;
                Add(parent);
                if (expanded.Contains(parent.Id) || search.Text.Length > 0)
                    foreach (var child in children.Where(x => matches || x.Name.Contains(search.Text, StringComparison.CurrentCultureIgnoreCase))) Add(child);
            }
            if (rows.Children.Count == 0) rows.Children.Add(Label(_l.Get(search.Text.Length > 0 ? "PhotosMemberNoFoldersMatch" : "PhotosMemberNoFolders")));
        }
        async Task Folders(SynologyPhotoSharedMember member)
        {
            if (!Current() || busy || pending) return; mode = 2; busy = true; folderMember = member; folderDraft = null; reload = null; folderRisk = false; expanded.Clear();
            search.Text = ""; search.PlaceholderText = _l.Get("PhotosMemberFindFolder"); AutomationProperties.SetName(search, _l.Get("PhotosMemberFindFolder")); Root(); message.Text = _l.Get("PhotosLoadingDescription"); State();
            try
            {
                var edit = edits.GetValueOrDefault(member.Id) ?? new(member.Id, await _model.Repository.SharedMemberFoldersAsync(member.Id, _viewCancellation.Token)); if (!Current()) return;
                folderDraft = edit; actions.Orientation = Orientation.Vertical;
                foreach (var level in Enum.GetValues<SynologyPhotoFolderMemberRole>())
                {
                    actions.Children.Add(Label(_l.Get(MemberFolderRoleKey(level))));
                    var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
                    foreach (var grant in new[] { true, false })
                    {
                        var button = new Button { Content = _l.Get(grant ? "PhotosMemberGrantEvery" : "PhotosMemberRevokeEvery"), IsEnabled = edit.Original.Count > 0 && edit.Original.All(x => x.Known) };
                        AutomationProperties.SetName(button, _l.Format(grant ? "PhotosMemberGrantAll" : "PhotosMemberRevokeAll", _l.Get(MemberFolderRoleKey(level))));
                        AutomationProperties.SetAutomationId(button, "PhotoMemberBatch-" + (grant ? "grant-" : "revoke-") + level);
                        button.Click += (_, _) => { if (folderDraft is null) return; folderDraft = folderDraft.Applying(new(grant, level)); folderRisk |= !grant && level == SynologyPhotoFolderMemberRole.View;
                            message.Text = folderRisk ? _l.Get("PhotosMemberChildrenWarning") : ""; FolderRows(); State(); }; line.Children.Add(button);
                    }
                    actions.Children.Add(line);
                }
                FolderRows(); message.Text = "";
            }
            catch (Exception error) { if (Current()) { message.Text = _l.Get(PreferenceErrorKey(error)); reload = () => Folders(member); } }
            finally { busy = false; State(); }
        }
        async Task Apply(SynologyPhotoSettingsChange result)
        {
            await _model.ApplySettingsChangeAsync(result);
            if (!Current() && !_disposed && ReferenceEquals(_dialog, dialog)) dialog.Hide();
            RenderPreviewControls();
        }
        async Task Load()
        {
            if (!Current() || busy) return; busy = true; confirming = false; original = null; reload = null; body.Children.Clear(); message.Text = _l.Get("PhotosLoadingDescription"); State();
            try
            {
                var unfinished = (await _model.Repository.SettingsChangesAsync(_viewCancellation.Token)).SingleOrDefault(x => x.Pending);
                if (unfinished is not null)
                {
                    if (unfinished.HasMemberChanges && !pending) { _model.BeginSharedMemberChange(); generation = _viewGeneration; }
                    var result = await _model.Repository.ReviewSettingsChangeAsync(unfinished.Id, _viewCancellation.Token); if (!Current()) return;
                    pending = result.Pending; await Apply(result); if (!Current()) return;
                    if (pending) { message.Text = _l.Get("PhotosPreferenceSaving"); reload = Load; return; }
                }
                pending = false; var snapshot = await _model.Repository.SharedMembersAsync(_viewCancellation.Token); if (!Current()) return;
                original = snapshot; members = snapshot.Members.ToList(); edits.Clear(); candidates = []; id = Guid.NewGuid(); message.Text = ""; Main();
            }
            catch (Exception error) { if (Current()) { message.Text = _l.Get(PreferenceErrorKey(error)); reload = Load; } }
            finally { busy = false; State(); }
        }
        search.TextChanged += (_, _) => { if (mode == 0) MainRows(); else if (mode == 1) CandidateRows(); else FolderRows(); };
        back.Click += (_, _) => { message.Text = ""; actions.Orientation = Orientation.Horizontal; Main(); };
        retry.Click += async (_, _) => { if (reload is { } action) await action(); };
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(3) }; timer.Tick += async (_, _) => { if (pending && !busy) await Load(); };
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true; if (!Current() || busy || pending) return;
            if (mode == 2 && folderDraft is not null && folderMember is not null)
            {
                var index = members.FindIndex(x => x.Id == folderMember.Id); if (index < 0) members.Add(folderMember); else members[index] = folderMember;
                if (folderDraft.CanSave) edits[folderMember.Id] = folderDraft; else edits.Remove(folderMember.Id);
                actions.Orientation = Orientation.Horizontal; message.Text = ""; Main(); return;
            }
            if (mode != 0 || original is null || !Changed() || !_model.Repository.SettingsSafety.SharedMembers) return;
            if (!confirming)
            {
                confirming = true; var changed = original.Members.Where(x => !members.Any(y => y.Id == x.Id)).Select(x => _l.Format("PhotosMemberRemovedSummary", x.Recipient.Name))
                    .Concat(members.Where(x => !original.Members.Contains(x)).Select(x => _l.Format("PhotosMemberSavedSummary", x.Recipient.Name,
                        _l.Get(x.Role == "management" ? "PhotosMemberManagement" : "PhotosMemberEntry"), _l.Get(x.AutoBackup ? "PhotosAutomaticOn" : "PhotosAutomaticOff"))))
                    .Concat(edits.Values.Select(edit => _l.Format("PhotosMemberFoldersSummary", members.Single(x => x.Id == edit.Member).Recipient.Name,
                        edit.Original.Count(x => x.DirectRole != edit.Expected(x))))).ToArray();
                message.Text = _l.Format("PhotosMemberConfirm", string.Join(Environment.NewLine, changed)); State(); return;
            }
            var deferral = args.GetDeferral(); busy = true; reload = null; message.Text = _l.Get("PhotosPreferenceSaving"); State();
            _model.BeginSharedMemberChange(); generation = _viewGeneration;
            try
            {
                var result = await _model.Repository.SetSharedMembersAsync(id, original, members.ToArray(), edits.Values.Where(x => x.CanSave).ToArray(), true);
                if (_disposed || generation != _viewGeneration) return; await Apply(result); if (!Current()) return;
                pending = result.Pending;
                if (result.State == SynologyPhotoChangeState.Completed) dialog.Hide();
                else { original = null; confirming = false; body.Children.Clear(); message.Text = _l.Get(pending ? "PhotosPreferenceSaving" : result.PartiallySaved ? "PhotosGlobalPartiallySaved" : "PhotosPreferenceSaveFailed"); reload = Load; }
            }
            catch (Exception error) { if (Current()) { original = null; confirming = false; body.Children.Clear(); message.Text = _l.Get(PreferenceErrorKey(error)); reload = Load; } }
            finally { busy = false; State(); deferral.Complete(); }
        };
        reload = Load; dialog.Closed += (_, _) => closed = true;
        try
        {
            if (MoreButton.Flyout.IsOpen) MoreButton.Flyout.Hide(); SetPhotoDialog(dialog); await _model.Automatic.YieldAsync();
            var showing = ShowPhotoDialogAsync(dialog); timer.Start(); await Load(); await showing;
        }
        finally { closed = true; timer.Stop(); if (ReferenceEquals(_dialog, dialog)) SetPhotoDialog(null); RenderPreviewControls(); }
    }
    private static string MemberFolderRoleKey(SynologyPhotoFolderMemberRole role) => role switch
    { SynologyPhotoFolderMemberRole.View => "PhotosShareRoleView", SynologyPhotoFolderMemberRole.Download => "PhotosShareRoleDownload", SynologyPhotoFolderMemberRole.Upload => "PhotosShareRoleUpload", _ => "PhotosFolderShareRoleManage" };
}
