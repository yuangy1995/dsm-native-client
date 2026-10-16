using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views.Photos;

/// <summary>分享表单只提交用户改动；未知成员/保护状态不补为默认值。</summary>
internal sealed class SynologyPhotoSharingEditor : StackPanel
{
    private readonly LocalizationService _l = LocalizationService.Current;
    private readonly SynologyPhotoSharing _original;
    private readonly ComboBox _access, _passwordMode, _expiryMode;
    private readonly PasswordBox _password;
    private readonly CalendarDatePicker _date;
    private readonly SynologyPhotoMemberEditor _members;
    internal event Action? Changed;
    internal SynologyPhotoSharingEditor(SynologyPhotoSharing original)
    {
        _original = original; Spacing = 12;
        _access = Choice("PhotosShareAccess", ["PhotosShareDisabled", "PhotosShareInvited", "PhotosShareView", "PhotosShareDownload"], (int)original.Access);
        _passwordMode = Choice("PhotosSharePassword", ["PhotosShareKeep", "PhotosShareReplacePassword", "PhotosShareClearPassword"], 0);
        _password = new PasswordBox { Header = _l.Get("PhotosShareNewPassword"), Visibility = Visibility.Collapsed };
        Children.Add(_password);
        _expiryMode = Choice("PhotosShareExpiration", ["PhotosShareKeep", "PhotosShareNoExpiration", "PhotosShareChooseDate"], 0);
        if (original.Expiration is > 0)
        {
            try { Children.Add(new TextBlock { Text = _l.Format("PhotosShareCurrentExpiry", DateTimeOffset.FromUnixTimeSeconds(original.Expiration.Value).ToLocalTime()), TextWrapping = TextWrapping.Wrap }); }
            catch (ArgumentOutOfRangeException) { }
        }
        _date = new CalendarDatePicker { Header = _l.Get("PhotosShareExpiration"), PlaceholderText = _l.Get("PhotosShareChooseDate"), Language = _l.ResolvedLanguage,
            Visibility = Visibility.Collapsed, HorizontalAlignment = HorizontalAlignment.Stretch };
        Children.Add(_date);
        _members = new(original.Members, original.Album.Conditional ? ["view", "download"] : ["view", "download", "upload"]);
        Children.Add(_members); _members.Changed += () => Changed?.Invoke();
        _access.SelectionChanged += (_, _) => Changed?.Invoke();
        _passwordMode.SelectionChanged += (_, _) => { _password.Visibility = _passwordMode.SelectedIndex == 1 ? Visibility.Visible : Visibility.Collapsed; if (_passwordMode.SelectedIndex != 1) _password.Password = ""; Changed?.Invoke(); };
        _password.PasswordChanged += (_, _) => Changed?.Invoke();
        _expiryMode.SelectionChanged += (_, _) => { _date.Visibility = _expiryMode.SelectedIndex == 2 ? Visibility.Visible : Visibility.Collapsed; Changed?.Invoke(); };
        _date.DateChanged += (_, _) => Changed?.Invoke();
    }
    private ComboBox Choice(string header, string[] keys, int selected)
    {
        var result = new ComboBox { Header = _l.Get(header), ItemsSource = keys.Select(_l.Get).ToArray(), SelectedIndex = selected, HorizontalAlignment = HorizontalAlignment.Stretch };
        Children.Add(result); return result;
    }
    internal void SetCandidates(IReadOnlyList<SynologyPhotoShareRecipient> values) => _members.SetCandidates(values);
    internal SynologyPhotoSharingEdit Input()
    {
        long? expiry = _expiryMode.SelectedIndex switch { 0 => null, 1 => 0, _ => ExpirationAtDayEnd(_date.Date) };
        if (_passwordMode.SelectedIndex == 1 && _password.Password.Length == 0) throw new ArgumentException();
        return new(_original, (SynologyPhotoLinkAccess)_access.SelectedIndex)
        {
            Members = _members.Changes, Expiration = expiry,
            PasswordChange = (SynologyPhotoPasswordChange)_passwordMode.SelectedIndex, Password = _passwordMode.SelectedIndex == 1 ? _password.Password : null,
        };
    }
    internal static long ExpirationAtDayEnd(DateTimeOffset? day)
    {
        if (day is null) throw new ArgumentException();
        var local = DateTime.SpecifyKind(day.Value.Date.AddDays(1).AddSeconds(-1), DateTimeKind.Unspecified);
        if (TimeZoneInfo.Local.IsInvalidTime(local)) throw new ArgumentException();
        var result = new DateTimeOffset(local, TimeZoneInfo.Local.GetUtcOffset(local)).ToUnixTimeSeconds();
        return result >= 0 ? result : throw new ArgumentException();
    }
    internal void ClearPassword() => _password.Password = "";
}
