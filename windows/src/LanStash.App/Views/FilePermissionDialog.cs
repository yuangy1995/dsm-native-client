using LanStash.App.Features.Files.Permissions;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

internal sealed class FilePermissionDialog : ContentDialog, IDisposable
{
    private readonly FilePermissionViewModel _model;
    private readonly LocalizationService _text = LocalizationService.Current;
    private readonly StackPanel _body = new() { Spacing = 12, MinWidth = 460, MaxWidth = 540 };
    private readonly InfoBar _message = new() { IsClosable = false };
    private readonly ProgressRing _loading = new() { Width = 32, Height = 32, HorizontalAlignment = HorizontalAlignment.Center };
    private readonly ContentControl _form = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch };
    private readonly StackPanel _memberResults = new() { Spacing = 8 };
    private readonly StackPanel _changes = new() { Spacing = 8 };
    private FilePermissionSnapshot? _renderedSnapshot;
    private CheckBox? _accessRisk, _ownerRisk, _scopeRisk;
    private string _memberRole = "rules";
    private bool _disposed;

    public FilePermissionDialog(FilePermissionViewModel model, XamlRoot root)
    {
        _model = model; XamlRoot = root; RequestedTheme = root.Content is FrameworkElement element ? element.ActualTheme : ElementTheme.Default;
        Title = _text.Get("FilePermissionsTitle"); PrimaryButtonText = _text.Get("ActionSave");
        SecondaryButtonText = _text.Get("FileShareRefreshAction"); CloseButtonText = _text.Get("ActionClose");
        DefaultButton = ContentDialogButton.None;
        AutomationProperties.SetAutomationId(this, "FilePermissionDialog");
        _body.Children.Add(_loading); _body.Children.Add(_message); _body.Children.Add(_form);
        Content = new ScrollViewer { Content = _body, MaxHeight = 480, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        PrimaryButtonClick += async (_, args) => { args.Cancel = true; await _model.SaveAsync(); };
        SecondaryButtonClick += async (_, args) => { args.Cancel = true; await _model.LoadAsync(); };
        Opened += async (_, _) => await _model.LoadAsync();
        _model.PropertyChanged += Changed;
        Render();
    }

    private void Changed(object? sender, System.ComponentModel.PropertyChangedEventArgs args) => Render();
    private void Render()
    {
        if (_disposed) return;
        _loading.IsActive = _model.IsBusy;
        _loading.Visibility = _model.IsBusy ? Visibility.Visible : Visibility.Collapsed;
        IsPrimaryButtonEnabled = _model.CanSave;
        IsSecondaryButtonEnabled = !_model.IsBusy;
        _message.IsOpen = _model.MessageKey is not null;
        _message.Message = _model.MessageKey is { } key ? _text.Get(key) : "";
        _message.Severity = _model.Progress?.Outcome.Status == MutationResultStatus.ConfirmedSuccess ? InfoBarSeverity.Success :
            _model.IsPending ? InfoBarSeverity.Warning : InfoBarSeverity.Error;
        if (!ReferenceEquals(_renderedSnapshot, _model.Snapshot)) BuildForm();
        _form.IsEnabled = !_model.IsBusy && !_model.IsPending;
        if (_accessRisk is not null) _accessRisk.IsChecked = _model.ConfirmedAccessRemoval;
        if (_ownerRisk is not null) _ownerRisk.IsChecked = _model.ConfirmedOwner;
        if (_scopeRisk is not null) _scopeRisk.IsChecked = _model.ConfirmedScope;
        RenderMembers();
        RenderChanges();
    }

    private void BuildForm()
    {
        _renderedSnapshot = _model.Snapshot;
        _accessRisk = _ownerRisk = _scopeRisk = null;
        _memberResults.Children.Clear();
        if (_memberResults.Parent is Panel previous) previous.Children.Remove(_memberResults);
        if (_changes.Parent is Panel previousChanges) previousChanges.Children.Remove(_changes);
        if (_model.Snapshot is not { } snapshot) { _form.Content = null; return; }
        var panel = new StackPanel { Spacing = 12 };
        panel.Children.Add(Label(snapshot.Target.Name));
        if (!string.IsNullOrEmpty(snapshot.ActingAccount)) panel.Children.Add(Label(_text.Format("FilePermissionsActingAccount", snapshot.ActingAccount)));
        panel.Children.Add(Label(_text.Format("FilePermissionsCurrentOwner", snapshot.Owner?.Name ?? snapshot.Target.Owner ?? "")));
        if (!snapshot.IsAcl) panel.Children.Add(Label(_text.Format("FilePermissionsCurrentGroup", snapshot.Group ?? "")));
        if (!snapshot.CanChangePermissions && snapshot.Owner?.CanChange != true)
            panel.Children.Add(Label(_text.Get("FilePermissionsReadOnly")));
        if (snapshot.IsAcl)
        {
            panel.Children.Add(Label(_text.Get("FilePermissionsExplicit")));
            if (_model.Rules.Count == 0) panel.Children.Add(Label(_text.Get("FilePermissionsNoRules")));
            for (var index = 0; index < _model.Rules.Count; index++) panel.Children.Add(RuleEditor(_model.Rules[index], index));
            var add = Button("FilePermissionsAddRule", () => ShowMembers("rules"));
            add.IsEnabled = snapshot.CanChangePermissions;
            panel.Children.Add(add);
            var inherited = snapshot.Rules.Where(rule => rule.Level > 0).ToArray();
            if (inherited.Length > 0)
            {
                panel.Children.Add(Label(_text.Get("FilePermissionsInherited")));
                foreach (var rule in inherited) panel.Children.Add(RuleEditor(rule, null));
            }
        }
        else
        {
            panel.Children.Add(Label(_text.Format("FilePermissionsOriginalMode", snapshot.PosixMode ?? "")));
            for (var index = 0; index < 3; index++)
            {
                var position = index;
                var row = new StackPanel { Spacing = 8 };
                row.Children.Add(Label(_text.Get(index == 0 ? "FilePermissionsOwnerRole" : index == 1 ? "FilePermissionsGroupRole" : "FilePermissionsEveryoneRole")));
                var choices = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 16 };
                foreach (var bit in new[] { 4, 2, 1 })
                {
                    var selectedBit = bit;
                    var choice = new CheckBox { Content = _text.Get(bit == 4 ? "FilePermissionsPosixRead" : bit == 2 ? "FilePermissionsPosixWrite" : "FilePermissionsPosixExecute"),
                        IsChecked = ((_model.PosixMode[position] - '0') & bit) != 0, IsEnabled = snapshot.CanChangePermissions };
                    choice.Click += (_, _) =>
                    {
                        var digits = _model.PosixMode.ToCharArray(); var old = digits[position] - '0';
                        digits[position] = (char)('0' + (choice.IsChecked == true ? old | selectedBit : old & ~selectedBit));
                        _model.PosixMode = new(digits); _model.DraftChanged();
                    };
                    choices.Children.Add(choice);
                }
                row.Children.Add(choices); panel.Children.Add(row);
            }
        }
        if (snapshot.Owner?.CanChange == true || !snapshot.IsAcl && snapshot.CanChangePermissions)
        {
            panel.Children.Add(Button("FilePermissionsChangeOwner", () => ShowMembers("owner")));
            if (_model.Owner is { } owner) panel.Children.Add(Label(_text.Format("FilePermissionsNewOwner", owner.Name)));
        }
        if (!snapshot.IsAcl && snapshot.CanChangePermissions)
        {
            panel.Children.Add(Button("FilePermissionsChangeGroup", () => ShowMembers("group")));
            if (_model.Group is { } group) panel.Children.Add(Label(_text.Format("FilePermissionsNewGroup", group.Name)));
        }
        panel.Children.Add(_memberResults);
        panel.Children.Add(_changes);
        if (snapshot.CanChangePermissions || snapshot.Owner?.CanChange == true)
        {
            if (snapshot.Target.IsDirectory)
            {
                var recursive = new CheckBox { Content = _text.Get("FilePermissionsApplyChildren"), IsChecked = _model.Recursive };
                recursive.Click += (_, _) => { _model.Recursive = recursive.IsChecked == true; _model.DraftChanged(); BuildForm(); Render(); };
                panel.Children.Add(recursive);
            }
            _accessRisk = Risk("FilePermissionsAccessRisk", value => _model.ConfirmedAccessRemoval = value);
            panel.Children.Add(_accessRisk);
            if (_model.Owner is not null || _model.Group is not null)
            { _ownerRisk = Risk("FilePermissionsOwnerRisk", value => _model.ConfirmedOwner = value); panel.Children.Add(_ownerRisk); }
            if (_model.Recursive)
            { _scopeRisk = Risk("FilePermissionsScopeRisk", value => _model.ConfirmedScope = value); panel.Children.Add(_scopeRisk); }
        }
        _form.Content = panel;
    }

    private Expander RuleEditor(FileAclRule rule, int? index)
    {
        var editor = new StackPanel { Spacing = 8 };
        var writable = index is not null && _model.Snapshot?.CanChangePermissions == true;
        var effect = new ComboBox { Header = _text.Get("FilePermissionsEffect"), SelectedIndex = (int)rule.Effect,
            IsEnabled = writable, HorizontalAlignment = HorizontalAlignment.Stretch };
        effect.Items.Add(_text.Get("FilePermissionsAllow")); effect.Items.Add(_text.Get("FilePermissionsDeny")); effect.SelectedIndex = (int)rule.Effect;
        effect.SelectionChanged += (_, _) => { if (index is { } i) { _model.Rules[i] = _model.Rules[i] with { Effect = (FileAclEffect)effect.SelectedIndex }; _model.DraftChanged(); } };
        editor.Children.Add(effect);
        foreach (var right in Enum.GetValues<FileAclRights>().Where(value => value != FileAclRights.None))
        {
            var choice = new CheckBox { Content = _text.Get(RightKey(right)), IsChecked = rule.Rights.HasFlag(right), IsEnabled = writable };
            choice.Click += (_, _) => { if (index is { } i) { var row = _model.Rules[i]; _model.Rules[i] = row with {
                Rights = choice.IsChecked == true ? row.Rights | right : row.Rights & ~right }; _model.DraftChanged(); } };
            editor.Children.Add(choice);
        }
        foreach (var scope in Enum.GetValues<FileAclInheritance>().Where(value => value != FileAclInheritance.None))
        {
            var choice = new CheckBox { Content = _text.Get(InheritanceKey(scope)), IsChecked = rule.Inheritance.HasFlag(scope), IsEnabled = writable };
            choice.Click += (_, _) => { if (index is { } i) { var row = _model.Rules[i]; _model.Rules[i] = row with {
                Inheritance = choice.IsChecked == true ? row.Inheritance | scope : row.Inheritance & ~scope }; _model.DraftChanged(); } };
            editor.Children.Add(choice);
        }
        if (writable) editor.Children.Add(Button("FilePermissionsRemoveRule", () => { _model.Rules.RemoveAt(index!.Value); _model.DraftChanged(); BuildForm(); Render(); }));
        return new Expander { Header = string.IsNullOrEmpty(rule.OwnerName) ? _text.Get("FilePermissionsUnknownAccount") : rule.OwnerName,
            HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch, Content = editor };
    }

    private bool _membersVisible;
    private void RenderChanges()
    {
        _changes.Children.Clear();
        if (_model.Snapshot is not { } snapshot || !_model.HasChanges) return;
        _changes.Children.Add(Label(_text.Get("FilePermissionsChanges")));
        if (_model.Owner is { } owner) _changes.Children.Add(Label(_text.Format("FilePermissionsOwnerDiff", snapshot.Owner?.Name ?? snapshot.Target.Owner ?? "", owner.Name)));
        if (_model.Group is { } group) _changes.Children.Add(Label(_text.Format("FilePermissionsGroupDiff", snapshot.Group ?? "", group.Name)));
        if (!snapshot.IsAcl && snapshot.PosixMode != _model.PosixMode)
            _changes.Children.Add(Label(_text.Format("FilePermissionsModeDiff", snapshot.PosixMode ?? "", _model.PosixMode)));
        if (!_model.RulesChanged) return;
        var before = snapshot.Rules.Where(rule => rule.Level == 0).ToList();
        var after = _model.Rules.ToList();
        foreach (var rule in before.ToArray())
            if (after.Remove(rule)) before.Remove(rule);
        foreach (var rule in before) _changes.Children.Add(Label(_text.Format("FilePermissionsBeforeRule", RuleSummary(rule))));
        foreach (var rule in after) _changes.Children.Add(Label(_text.Format("FilePermissionsAfterRule", RuleSummary(rule))));
    }
    private string RuleSummary(FileAclRule rule) => _text.Format("FilePermissionsRuleSummary", rule.OwnerName,
        _text.Get(rule.Effect == FileAclEffect.Allow ? "FilePermissionsAllow" : "FilePermissionsDeny"),
        string.Join(_text.Get("FilePermissionsSeparator"), Enum.GetValues<FileAclRights>().Where(value => value != FileAclRights.None && rule.Rights.HasFlag(value)).Select(value => _text.Get(RightKey(value)))),
        string.Join(_text.Get("FilePermissionsSeparator"), Enum.GetValues<FileAclInheritance>().Where(value => value != FileAclInheritance.None && rule.Inheritance.HasFlag(value)).Select(value => _text.Get(InheritanceKey(value)))));
    private TextBox? _memberQuery;
    private void ShowMembers(string role)
    {
        _memberRole = role; _membersVisible = true;
        _memberQuery = new TextBox { Header = _text.Get("FilePermissionsFindMember") };
        RenderMembers(); _memberResults.StartBringIntoView();
        _ = _model.LoadMembersAsync("");
    }
    private void RenderMembers()
    {
        _memberResults.Children.Clear();
        if (!_membersVisible || _memberQuery is null) return;
        _memberResults.Children.Add(_memberQuery);
        _memberResults.Children.Add(Button("FilePermissionsFindMember", () => { _ = _model.LoadMembersAsync(_memberQuery.Text); }));
        if (_model.IsLoadingMembers) { _memberResults.Children.Add(new ProgressRing { IsActive = true, Width = 24, Height = 24 }); return; }
        if (_model.MembersFailed) { _memberResults.Children.Add(Label(_text.Get("FileShareMembersError"))); return; }
        var members = _model.Members.Where(member => _memberRole != "group" || member.Kind == FileSharePrincipalKind.Group)
            .Where(member => _memberRole != "owner" || _model.Snapshot?.IsAcl == true || member.Kind == FileSharePrincipalKind.User).ToArray();
        if (members.Length == 0) _memberResults.Children.Add(Label(_text.Get("FileShareMembersEmpty")));
        foreach (var member in members)
        {
            var button = new Button { Content = _text.Format(member.Kind == FileSharePrincipalKind.User ? "FilePermissionsUserName" : "FilePermissionsGroupName", member.Name),
                MinHeight = 44, HorizontalAlignment = HorizontalAlignment.Stretch };
            button.Click += (_, _) =>
            {
                if (_memberRole == "owner") _model.Owner = member;
                else if (_memberRole == "group") _model.Group = member;
                else _model.Rules.Add(new(member.Kind == FileSharePrincipalKind.User ? "user" : "group", member.Name, null, null,
                    FileAclEffect.Allow, FileAclRights.ReadData | FileAclRights.ReadAttributes | FileAclRights.ReadExtendedAttributes | FileAclRights.ReadPermissions,
                    FileAclInheritance.ThisFolder));
                _membersVisible = false; _model.DraftChanged(); BuildForm(); Render();
            };
            _memberResults.Children.Add(button);
        }
    }
    private CheckBox Risk(string key, Action<bool> apply)
    {
        var check = new CheckBox { Content = Label(_text.Get(key)), HorizontalContentAlignment = HorizontalAlignment.Stretch };
        AutomationProperties.SetAutomationId(check, key);
        check.Checked += (_, _) => { apply(true); _model.Notify(); };
        check.Unchecked += (_, _) => { apply(false); _model.Notify(); };
        return check;
    }
    private Button Button(string key, Action action)
    {
        var button = new Button { Content = _text.Get(key), MinHeight = 44 };
        AutomationProperties.SetAutomationId(button, key); button.Click += (_, _) => action(); return button;
    }
    private static TextBlock Label(string text) => new() { Text = text, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
    private static string InheritanceKey(FileAclInheritance value) => value switch
    {
        FileAclInheritance.ChildFiles => "FilePermissionsChildFiles", FileAclInheritance.ChildFolders => "FilePermissionsChildFolders",
        FileAclInheritance.ThisFolder => "FilePermissionsThisFolder", _ => "FilePermissionsAllDescendants",
    };
    private static string RightKey(FileAclRights value) => value switch
    {
        FileAclRights.ReadData => "FilePermissionsRead", FileAclRights.WriteData => "FilePermissionsWrite",
        FileAclRights.Execute => "FilePermissionsExecute", FileAclRights.Append => "FilePermissionsAppend",
        FileAclRights.Delete => "FilePermissionsDelete", FileAclRights.DeleteChildren => "FilePermissionsDeleteChildren",
        FileAclRights.ReadAttributes => "FilePermissionsReadAttributes", FileAclRights.WriteAttributes => "FilePermissionsWriteAttributes",
        FileAclRights.ReadExtendedAttributes => "FilePermissionsReadExtended", FileAclRights.WriteExtendedAttributes => "FilePermissionsWriteExtended",
        FileAclRights.ReadPermissions => "FilePermissionsReadPermissions", FileAclRights.ChangePermissions => "FilePermissionsChangePermissions",
        _ => "FilePermissionsTakeOwnership",
    };
    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true; _model.PropertyChanged -= Changed; _model.Dispose();
    }
}
