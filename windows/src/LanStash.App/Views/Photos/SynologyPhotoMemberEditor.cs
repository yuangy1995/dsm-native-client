using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views.Photos;

/// <summary>相册和目录共用成员编辑控件，允许角色由各自契约提供。</summary>
internal sealed class SynologyPhotoMemberEditor : StackPanel
{
    private readonly LocalizationService _l = LocalizationService.Current;
    private readonly StackPanel _members = new() { Spacing = 8 };
    private readonly TextBox _search;
    private readonly ListView _candidates;
    private readonly Button _add;
    private readonly TextBlock _candidateEmpty = new() { TextWrapping = TextWrapping.Wrap, Visibility = Visibility.Collapsed };
    private readonly List<SynologyPhotoShareGrant> _grants;
    private IReadOnlyList<SynologyPhotoShareRecipient> _available = [];
    private bool _membersChanged, _candidatesLoaded;
    private readonly IReadOnlyList<SynologyPhotoShareGrant>? _original;
    private readonly string[] _roles;
    internal event Action? Changed;
    internal SynologyPhotoMemberEditor(IReadOnlyList<SynologyPhotoShareGrant>? original, string[] roles)
    {
        _original = original; _roles = roles; _grants = original?.ToList() ?? []; Spacing = 12;
        Children.Add(new TextBlock { Text = _l.Get("PhotosShareMembers"), FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        Children.Add(_members);
        _search = new TextBox { Header = _l.Get("PhotosShareFindMembers"), Visibility = original is null ? Visibility.Collapsed : Visibility.Visible };
        _candidates = new ListView { MaxHeight = 160, SelectionMode = ListViewSelectionMode.Single, DisplayMemberPath = nameof(MemberChoice.Title), Visibility = _search.Visibility };
        AutomationProperties.SetName(_candidates, _l.Get("PhotosShareAvailableMembers"));
        _add = new Button { Content = _l.Get("PhotosShareAddMember"), IsEnabled = false, Visibility = _search.Visibility };
        foreach (var control in new FrameworkElement[] { _search, _candidates, _candidateEmpty, _add }) Children.Add(control);
        _search.TextChanged += (_, _) => RenderCandidates();
        _candidates.SelectionChanged += (_, _) => _add.IsEnabled = _candidates.SelectedItem is MemberChoice;
        _add.Click += (_, _) =>
        {
            if (_candidates.SelectedItem is not MemberChoice choice) return;
            _grants.Add(new(choice.Member, "view")); _membersChanged = true; RenderMembers(); RenderCandidates(); Changed?.Invoke();
        };
        RenderMembers();
    }
    private sealed record MemberChoice(SynologyPhotoShareRecipient Member, string Title);
    internal void SetCandidates(IReadOnlyList<SynologyPhotoShareRecipient> values) { _available = values; _candidatesLoaded = true; RenderCandidates(); }
    private string RecipientTitle(SynologyPhotoShareRecipient recipient) => _l.Format("PhotosShareRecipient", string.IsNullOrEmpty(recipient.Name) ? _l.Get("PhotosShareSavedMember") : recipient.Name,
        _l.Get(recipient.Id.Type == "group" ? "PhotosShareGroup" : "PhotosShareUser"));
    private void RenderCandidates()
    {
        var values = _available.Where(item => !_grants.Any(grant => grant.Id == item.Id) &&
            item.Name.Contains(_search.Text, StringComparison.CurrentCultureIgnoreCase)).Select(item => new MemberChoice(item, RecipientTitle(item))).ToArray();
        _candidates.ItemsSource = values;
        _candidateEmpty.Text = _l.Get(_search.Text.Length > 0 ? "PhotosShareNoMatches" : "PhotosShareNoCandidates");
        _candidateEmpty.Visibility = _candidatesLoaded && values.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
    }
    private void RenderMembers()
    {
        _members.Children.Clear();
        if (_original is null || _grants.Count == 0)
            _members.Children.Add(new TextBlock { Text = _l.Get(_original is null ? "PhotosShareMembersUnavailable" : "PhotosShareNoMembers"), TextWrapping = TextWrapping.Wrap });
        foreach (var member in _grants.ToArray())
        {
            var row = new StackPanel { Spacing = 6 }; var title = RecipientTitle(member.Recipient);
            row.Children.Add(new TextBlock { Text = title, TextWrapping = TextWrapping.Wrap });
            var roles = _roles.ToList();
            if (!roles.Contains(member.Role)) roles.Add(member.Role);
            var role = new ComboBox { HorizontalAlignment = HorizontalAlignment.Stretch, ItemsSource = roles.Select(value => _l.Get(value switch
                { "view" => "PhotosShareRoleView", "download" => "PhotosShareRoleDownload", "upload" => "PhotosShareRoleUpload", "manage" => "PhotosFolderShareRoleManage", _ => "PhotosShareRoleOther" })).ToArray(), SelectedIndex = roles.IndexOf(member.Role) };
            AutomationProperties.SetName(role, _l.Format("PhotosShareMemberRole", title));
            role.SelectionChanged += (_, _) => { var index = _grants.FindIndex(item => item.Id == member.Id); if (index >= 0 && role.SelectedIndex >= 0) { _grants[index] = _grants[index] with { Role = roles[role.SelectedIndex] }; _membersChanged = true; Changed?.Invoke(); } };
            var remove = new Button { Content = _l.Get("PhotosShareRemoveMember") }; AutomationProperties.SetName(remove, _l.Format("PhotosShareRemoveNamedMember", title));
            remove.Click += (_, _) => { _grants.RemoveAll(item => item.Id == member.Id); _membersChanged = true; RenderMembers(); RenderCandidates(); Changed?.Invoke(); };
            row.Children.Add(role); row.Children.Add(remove); _members.Children.Add(row);
        }
    }
    internal IReadOnlyList<SynologyPhotoShareGrant>? Changes => _membersChanged ? _grants.ToArray() : null;
}
