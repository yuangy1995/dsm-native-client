using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views.Photos;

internal sealed class SynologyPhotoFolderSharingEditor : StackPanel
{
    private readonly LocalizationService _l = LocalizationService.Current;
    private readonly SynologyPhotoFolderSharing _original;
    private readonly ComboBox _access, _passwordMode;
    private readonly PasswordBox _password;
    private readonly CheckBox _apply;
    private readonly SynologyPhotoMemberEditor _members;
    internal event Action? Changed;
    internal SynologyPhotoFolderSharingEditor(SynologyPhotoFolderSharing original)
    {
        _original = original; Spacing = 12;
        _access = new() { Header = _l.Get("PhotosShareAccess"), HorizontalAlignment = HorizontalAlignment.Stretch,
            ItemsSource = new[] { "PhotosFolderShareManagement", "PhotosShareInvited", "PhotosShareView", "PhotosShareDownload" }.Select(_l.Get).ToArray(), SelectedIndex = (int)original.Access };
        _passwordMode = new() { Header = _l.Get("PhotosSharePassword"), HorizontalAlignment = HorizontalAlignment.Stretch,
            ItemsSource = new[] { "PhotosShareKeep", "PhotosShareReplacePassword", "PhotosShareClearPassword" }.Select(_l.Get).ToArray(), SelectedIndex = 0 };
        _password = new() { Header = _l.Get("PhotosShareNewPassword"), Visibility = Visibility.Collapsed };
        _apply = new() { Content = new TextBlock { Text = _l.Get("PhotosFolderShareApply"), TextWrapping = TextWrapping.Wrap },
            IsChecked = original.AppliesToSubfolders, Visibility = original.Depth == 1 ? Visibility.Visible : Visibility.Collapsed };
        _members = new(original.Members, ["view", "download", "upload", "manage"]);
        Children.Add(_access);
        Children.Add(new TextBlock { Text = _l.Get(original.HasPassword switch { true => "PhotosFolderSharePasswordOn", false => "PhotosFolderSharePasswordOff", _ => "PhotosFolderSharePasswordUnknown" }), TextWrapping = TextWrapping.Wrap });
        foreach (var control in new FrameworkElement[] { _passwordMode, _password, _apply, _members }) Children.Add(control);
        _access.SelectionChanged += (_, _) => Changed?.Invoke();
        _passwordMode.SelectionChanged += (_, _) => { _password.Visibility = _passwordMode.SelectedIndex == 1 ? Visibility.Visible : Visibility.Collapsed; if (_passwordMode.SelectedIndex != 1) _password.Password = ""; Changed?.Invoke(); };
        _password.PasswordChanged += (_, _) => Changed?.Invoke(); _apply.Checked += (_, _) => Changed?.Invoke(); _apply.Unchecked += (_, _) => Changed?.Invoke();
        _members.Changed += () => Changed?.Invoke();
    }
    internal void SetCandidates(IReadOnlyList<SynologyPhotoShareRecipient> values) => _members.SetCandidates(values);
    internal SynologyPhotoFolderSharingEdit Input()
    {
        if (_passwordMode.SelectedIndex == 1 && _password.Password.Length == 0) throw new ArgumentException();
        return new(_original, (SynologyPhotoFolderAccess)_access.SelectedIndex, _apply.IsChecked == true)
        { Members = _members.Changes, PasswordChange = (SynologyPhotoPasswordChange)_passwordMode.SelectedIndex, Password = _passwordMode.SelectedIndex == 1 ? _password.Password : null };
    }
    internal void ClearPassword() => _password.Password = "";
}
