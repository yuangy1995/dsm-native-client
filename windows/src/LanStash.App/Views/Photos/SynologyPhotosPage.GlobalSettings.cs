using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views.Photos;

public sealed partial class SynologyPhotosPage
{
    private async void PhotoGlobalSettings_Click(object sender, RoutedEventArgs args) => await ShowPhotoGlobalSettingsAsync();
    private async Task ShowPhotoGlobalSettingsAsync()
    {
        if (_disposed || _dialog is not null) return;
        var generation = _viewGeneration; var closed = false; var busy = false; var cacheBusy = false; var pending = false;
        var confirming = false; var clearOnly = false; var id = Guid.NewGuid();
        SynologyPhotoGlobalSettings? original = null; SynologyPhotoConversionCache? cache = null;
        var toggles = new Dictionary<SynologyPhotoGlobalKind, ToggleSwitch>(); var extensions = new Dictionary<string, CheckBox>(StringComparer.Ordinal);
        var fields = new StackPanel { Spacing = 12, MinWidth = 280, MaxWidth = 560 };
        var cacheText = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var cacheRefresh = new Button { Content = _l.Get("PhotosRefresh") };
        var cacheClear = new Button { Content = _l.Get("PhotosClearConversionCache") };
        AutomationProperties.SetAutomationId(cacheClear, "PhotoClearConversionCache"); AutomationProperties.SetAutomationId(cacheRefresh, "PhotoRefreshConversionCache");
        var cachePanel = new StackPanel { Spacing = 8 }; cachePanel.Children.Add(new TextBlock { Text = _l.Get("PhotosConversionCache"), Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"] });
        cachePanel.Children.Add(cacheText); var cacheButtons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        cacheButtons.Children.Add(cacheRefresh); cacheButtons.Children.Add(cacheClear); cachePanel.Children.Add(cacheButtons);
        var sections = new StackPanel { Spacing = 20 }; sections.Children.Add(fields); sections.Children.Add(cachePanel);
        var form = new ContentControl { Content = sections, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        var message = new TextBlock { TextWrapping = TextWrapping.Wrap }; var retry = new Button { Content = _l.Get("PhotosRetry") };
        var back = new Button { Content = _l.Get("PhotosGlobalBack") };
        var panel = new StackPanel { Spacing = 12 }; panel.Children.Add(form); panel.Children.Add(message); panel.Children.Add(retry); panel.Children.Add(back);
        var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = _l.Get("PhotosGlobalSettings"),
            PrimaryButtonText = _l.Get("PhotosSaveChanges"), CloseButtonText = _l.Get("PhotosClose"), IsPrimaryButtonEnabled = false,
            Content = new ScrollViewer { Content = panel, MaxHeight = 550, VerticalScrollBarVisibility = ScrollBarVisibility.Auto } };
        bool Current() => !closed && !_disposed && generation == _viewGeneration;
        SynologyPhotoGlobalSettings? Target() => original?.Applying(toggles.Where(pair => pair.Value.IsOn).Select(pair => pair.Key).ToHashSet(),
            original.ExcludedExtensions is null ? null : extensions.Where(pair => pair.Value.IsChecked == true).Select(pair => pair.Key).ToArray());
        bool Changed() => original is not null && Target() is { } target && !original.SameValues(target);
        void Render()
        {
            if (!Current()) return;
            form.Visibility = Visible(!confirming); form.IsEnabled = !busy && !pending;
            cacheRefresh.IsEnabled = !cacheBusy && !busy && !pending; cacheClear.IsEnabled = !cacheBusy && !busy && !pending && cache?.CanClear == true;
            cachePanel.Visibility = Visible(original is not null);
            dialog.PrimaryButtonText = _l.Get(confirming ? clearOnly ? "PhotosClearConversionCache" : "PhotosSharedConfirm" : "PhotosSaveChanges");
            dialog.IsPrimaryButtonEnabled = !busy && !pending && (confirming ? clearOnly ? cache?.CanClear == true : Changed() : Changed());
            back.Visibility = Visible(confirming && !busy); retry.Visibility = Visible(!confirming && !busy && (pending || original is null));
            message.Visibility = Visible(message.Text.Length > 0);
        }
        async Task LoadCache()
        {
            if (!Current() || cacheBusy) return; cacheBusy = true; cacheText.Text = _l.Get("PhotosLoadingDescription"); Render();
            try
            {
                var result = await _model.Repository.ConversionCacheAsync(_viewCancellation.Token); if (!Current()) return; cache = result;
                cacheText.Text = result.IsClearing ? _l.Get("PhotosConversionCacheClearing") : _l.Format("PhotosConversionCacheSize", result.SizeBytes.ToString("N0", System.Globalization.CultureInfo.CurrentCulture));
            }
            catch (Exception) { if (Current()) { cache = null; cacheText.Text = _l.Get("PhotosConversionCacheFailed"); } }
            finally { cacheBusy = false; Render(); }
        }
        async Task Apply(SynologyPhotoSettingsChange result)
        {
            await _model.ApplySettingsChangeAsync(result);
            if (!Current() && !_disposed && ReferenceEquals(_dialog, dialog)) dialog.Hide();
            RenderPreviewControls();
        }
        async Task Load()
        {
            if (!Current() || busy) return; busy = true; original = null; confirming = false; message.Text = _l.Get("PhotosLoadingDescription"); Render();
            try
            {
                var unfinished = (await _model.Repository.SettingsChangesAsync(_viewCancellation.Token)).SingleOrDefault(value => value.Pending);
                if (unfinished is not null)
                {
                    var result = await _model.Repository.ReviewSettingsChangeAsync(unfinished.Id, _viewCancellation.Token); if (!Current()) return;
                    await Apply(result); if (!Current()) return; pending = result.Pending;
                    if (pending) { fields.Children.Clear(); message.Text = _l.Get("PhotosPreferenceSaving"); return; }
                }
                pending = false; var snapshot = await _model.Repository.GlobalSettingsAsync(_viewCancellation.Token); if (!Current()) return;
                original = snapshot; id = Guid.NewGuid(); fields.Children.Clear(); toggles.Clear(); extensions.Clear();
                foreach (var kind in Enum.GetValues<SynologyPhotoGlobalKind>())
                {
                    if (snapshot.Value(kind) is not { } value) continue;
                    var key = GlobalTitle(kind); var toggle = new ToggleSwitch { Header = _l.Get(key), IsOn = value,
                        IsEnabled = snapshot.Editable(kind) && (kind is not (SynologyPhotoGlobalKind.UserSharing or SynologyPhotoGlobalKind.GuestInfo) || _model.Repository.SettingsSafety.GlobalSharingChanges),
                        OnContent = _l.Get("PhotosAutomaticOn"), OffContent = _l.Get("PhotosAutomaticOff") };
                    AutomationProperties.SetName(toggle, _l.Get(key)); AutomationProperties.SetAutomationId(toggle, key);
                    toggles.Add(kind, toggle); toggle.Toggled += (_, _) => Render(); fields.Children.Add(toggle);
                }
                if (!_model.Repository.SettingsSafety.GlobalSharingChanges && (snapshot.UserSharing is not null || snapshot.GuestInfo is not null))
                    fields.Children.Add(new TextBlock { Text = _l.Get("PhotosGlobalSharingUseWeb"), TextWrapping = TextWrapping.Wrap });
                if (snapshot.OriginalJpeg is not null && snapshot.HasHevc != true) fields.Children.Add(new TextBlock { Text = _l.Get("PhotosGlobalCodecUnavailable"), TextWrapping = TextWrapping.Wrap });
                if (snapshot.ExcludedExtensions is not null)
                {
                    var options = new StackPanel { Spacing = 4 };
                    foreach (var extension in SynologyPhotoGlobalSettings.SupportedExtensions.Concat(snapshot.ExcludedExtensions).Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal))
                    {
                        var check = new CheckBox { Content = extension, IsChecked = snapshot.ExcludedExtensions.Contains(extension, StringComparer.Ordinal) };
                        AutomationProperties.SetAutomationId(check, "PhotoExcludedExtension" + extension); extensions.Add(extension, check);
                        check.Checked += (_, _) => Render(); check.Unchecked += (_, _) => Render(); options.Children.Add(check);
                    }
                    fields.Children.Add(new Expander { Header = _l.Get("PhotosGlobalExcludedFormats"), Content = options, HorizontalAlignment = HorizontalAlignment.Stretch });
                }
                if (toggles.Count == 0 && snapshot.ExcludedExtensions is null) fields.Children.Add(new TextBlock { Text = _l.Get("PhotosGlobalNoSettings"), TextWrapping = TextWrapping.Wrap });
                message.Text = ""; await LoadCache();
            }
            catch (Exception error) { if (Current()) message.Text = _l.Get(PreferenceErrorKey(error)); }
            finally { busy = false; Render(); }
        }
        string Warning()
        {
            if (clearOnly) return _l.Get("PhotosConversionCacheWarning");
            var target = Target()!; var keys = new List<string> { "PhotosGlobalWarning" };
            if (new[] { SynologyPhotoGlobalKind.People, SynologyPhotoGlobalKind.Subjects, SynologyPhotoGlobalKind.Similar }.Any(kind => original!.Value(kind) == true && target.Value(kind) == false)) keys.Add("PhotosGlobalRecognitionWarning");
            if (original!.UserSharing != target.UserSharing) keys.Add("PhotosGlobalSharingWarning");
            if (original.GuestInfo != target.GuestInfo) keys.Add("PhotosGlobalGuestWarning");
            if (!SynologyPhotoGlobalSettings.SameExtensions(original.ExcludedExtensions, target.ExcludedExtensions)) keys.Add("PhotosGlobalExcludedWarning");
            if (original.OriginalJpeg == true && target.OriginalJpeg == false) keys.Add("PhotosConversionCacheWarning");
            return string.Join("\n\n", keys.Select(_l.Get));
        }
        cacheRefresh.Click += async (_, _) => await LoadCache(); retry.Click += async (_, _) => await Load();
        cacheClear.Click += (_, _) => { if (!busy && !pending && cache?.CanClear == true) { clearOnly = true; confirming = true; message.Text = Warning(); Render(); } };
        back.Click += (_, _) => { confirming = false; clearOnly = false; message.Text = ""; Render(); };
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(3) };
        timer.Tick += async (_, _) => { if (pending && !busy) await Load(); else if (cache?.IsClearing == true && !busy && !confirming) await LoadCache(); };
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true; if (!Current() || busy || pending || original is null) return;
            if (!confirming) { if (!Changed()) return; clearOnly = false; confirming = true; message.Text = Warning(); Render(); return; }
            var deferral = args.GetDeferral(); busy = true; message.Text = _l.Get("PhotosPreferenceSaving"); Render();
            try
            {
                var result = clearOnly ? await _model.Repository.ClearConversionCacheAsync(id, cache!, true) : await _model.Repository.SetGlobalSettingsAsync(id, original, Target()!, true);
                // 关闭设置窗口不取消已提交的修改；同一页面仍应用实际结果。
                if (_disposed || generation != _viewGeneration) return;
                await Apply(result); if (!Current()) return; pending = result.Pending;
                if (result.State == SynologyPhotoChangeState.Completed)
                {
                    if (!clearOnly) dialog.Hide();
                    else { id = Guid.NewGuid(); confirming = false; clearOnly = false; message.Text = _l.Get("PhotosConversionCacheCleared"); await LoadCache(); }
                }
                else { original = null; confirming = false; message.Text = _l.Get(pending ? "PhotosPreferenceSaving" : result.PartiallySaved ? "PhotosGlobalPartiallySaved" : "PhotosPreferenceSaveFailed"); }
            }
            catch (Exception error) { if (Current()) { original = null; confirming = false; message.Text = _l.Get(PreferenceErrorKey(error)); } }
            finally { busy = false; Render(); deferral.Complete(); }
        };
        dialog.Closed += (_, _) => closed = true;
        try
        {
            if (MoreButton.Flyout.IsOpen) MoreButton.Flyout.Hide(); SetPhotoDialog(dialog); await _model.Automatic.YieldAsync();
            var showing = ShowPhotoDialogAsync(dialog); timer.Start(); await Load(); await showing;
        }
        finally { closed = true; timer.Stop(); if (ReferenceEquals(_dialog, dialog)) SetPhotoDialog(null); RenderPreviewControls(); }
    }
    private static string GlobalTitle(SynologyPhotoGlobalKind kind) => kind switch
    { SynologyPhotoGlobalKind.People => "PhotosCategoryPeople", SynologyPhotoGlobalKind.Subjects => "PhotosCategorySubjects", SynologyPhotoGlobalKind.Similar => "PhotosCategorySimilar",
      SynologyPhotoGlobalKind.UserSharing => "PhotosGlobalUserSharing", SynologyPhotoGlobalKind.GuestInfo => "PhotosGlobalGuestInfo", _ => "PhotosGlobalOriginalJpeg" };
}
