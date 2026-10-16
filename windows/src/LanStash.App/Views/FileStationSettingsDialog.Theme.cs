using System.Globalization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;

namespace LanStash.App.Views;

internal sealed partial class FileStationSettingsDialog
{
    private readonly StackPanel _themePicker = new() { Spacing = 10 };
    private readonly ListView _themeList = new() { MaxHeight = 180, MinHeight = 120, SelectionMode = ListViewSelectionMode.None, IsItemClickEnabled = true };
    private readonly TextBlock _themeEmpty = new() { TextWrapping = TextWrapping.WrapWholeWords, Margin = new(0, 16, 0, 16) };
    private readonly Func<Task<string?>>? _pickThemeImage;
    private long _themePreviewGeneration;
    private bool _themeListInitialized, _pickingThemeImage;
    private bool _themeLocalReadFailed;
    private void UpdateTheme(Func<FileStationTheme, FileStationTheme> change) { if (_model.Draft is FileStationTheme theme) _model.UpdateDraft(change(theme)); }
    private void RenderThemeEditor(FileStationTheme theme)
    {
        Check("FsThemeCustomLogo", theme.CustomLogo, v => { UpdateTheme(t => t with { CustomLogo = v, LogoImage = v ? t.LogoImage : null }); RebuildEditor(); });
        if (theme.CustomLogo)
        {
            _editor.Children.Add(Choice("FsThemeLogoPosition", theme.LogoPosition, Enum.GetValues<FileStationLogoPosition>(), v => UpdateTheme(t => t with { LogoPosition = v })));
            ThemeImageChoice(FileStationThemeImageKind.Logo, theme.LogoImage);
        }
        Check("FsThemeCustomBackground", theme.CustomBackground, v => { UpdateTheme(t => t with { CustomBackground = v, BackgroundImage = v ? t.BackgroundImage : null }); RebuildEditor(); });
        if (theme.CustomBackground)
        {
            _editor.Children.Add(Choice("FsThemeBackgroundPosition", theme.BackgroundPosition, Enum.GetValues<FileStationBackgroundPosition>(), v => UpdateTheme(t => t with { BackgroundPosition = v })));
            ThemeImageChoice(FileStationThemeImageKind.Background, theme.BackgroundImage);
        }
        var color = new ColorPicker { IsAlphaEnabled = false, IsAlphaSliderVisible = false, IsAlphaTextInputVisible = false,
            Color = Windows.UI.Color.FromArgb(255, byte.Parse(theme.BackgroundColor.Substring(1, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture),
                byte.Parse(theme.BackgroundColor.Substring(3, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture), byte.Parse(theme.BackgroundColor.Substring(5, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture)) };
        AutomationProperties.SetName(color, T("FsThemeColor"));
        color.ColorChanged += (_, args) => { if (!_rendering) UpdateTheme(t => t with { BackgroundColor = $"#{args.NewColor.R:X2}{args.NewColor.G:X2}{args.NewColor.B:X2}" }); };
        _editor.Children.Add(new Expander { Header = T("FsThemeColor"), Content = color, HorizontalAlignment = HorizontalAlignment.Stretch });
        var footer = new TextBox { Header = T("FsThemeFooter"), Text = theme.Footer, MaxLength = 512, TextWrapping = TextWrapping.Wrap, AcceptsReturn = false };
        AutomationProperties.SetAutomationId(footer, "FsThemeFooter"); footer.TextChanged += (_, _) => { if (!_rendering) UpdateTheme(t => t with { Footer = footer.Text }); }; _editor.Children.Add(footer);
        Check("FsThemeFooterHtml", theme.FooterUsesHtml, value => UpdateTheme(t => t with { FooterUsesHtml = value }));
    }
    private void ThemeImageChoice(FileStationThemeImageKind kind, FileStationThemeImage? image)
    {
        _editor.Children.Add(Label(image is null ? T("FsThemeCurrentImage") : image.Name));
        _editor.Children.Add(Button(kind == FileStationThemeImageKind.Logo ? "FsThemeChooseLogo" : "FsThemeChooseBackground", async () => await _model.OpenThemePickerAsync(kind)));
        if (image is not null) _editor.Children.Add(Button(kind == FileStationThemeImageKind.Logo ? "FsThemeKeepLogo" : "FsThemeKeepBackground", () => {
            UpdateTheme(t => kind == FileStationThemeImageKind.Logo ? t with { LogoImage = null } : t with { BackgroundImage = null }); RebuildEditor(); }));
    }
    private void RenderThemePicker()
    {
        _themePreviewGeneration++; _themePicker.Children.Clear(); _themePicker.Visibility = Show(_model.ThemePickerOpen);
        if (!_model.ThemePickerOpen) return;
        var heading = Label(T(_model.ThemeKind == FileStationThemeImageKind.Logo ? "FsThemeChooseLogo" : "FsThemeChooseBackground")); heading.FontSize = 20; _themePicker.Children.Add(heading);
        var source = new ComboBox { Header = T("FsThemeSource"), HorizontalAlignment = HorizontalAlignment.Stretch, IsEnabled = !_model.IsBusy && !_pickingThemeImage };
        AutomationProperties.SetAutomationId(source, "FsThemeSource");
        foreach (var value in Enum.GetValues<FileStationThemeImageSource>().Where(v => v != FileStationThemeImageSource.Default || _model.ThemeKind == FileStationThemeImageKind.Background))
            source.Items.Add(new ComboBoxItem { Tag = value, Content = T("FsThemeSource" + value) });
        source.SelectedItem = source.Items.Cast<ComboBoxItem>().First(v => Equals(v.Tag, _model.ThemeSource));
        source.SelectionChanged += async (_, _) => { if (!_rendering && source.SelectedItem is ComboBoxItem { Tag: FileStationThemeImageSource value }) await _model.SetThemeSourceAsync(value); };
        _themePicker.Children.Add(source);
        if (_model.ThemeMessageKey is { } messageKey) _themePicker.Children.Add(new InfoBar { IsOpen = true, IsClosable = false, Message = T(messageKey), Severity = messageKey == "FsThemeUploaded" ? InfoBarSeverity.Success : InfoBarSeverity.Warning });
        if (_themeLocalReadFailed) _themePicker.Children.Add(new InfoBar { IsOpen = true, IsClosable = false, Message = T("FsThemeLocalReadFailed"), Severity = InfoBarSeverity.Warning });
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var refresh = Button("FsThemeRefresh", async () => await _model.LoadThemeImagesAsync()); refresh.IsEnabled = !_model.IsBusy; actions.Children.Add(refresh);
        var upload = Button("FsThemeUpload", UploadThemeImage); upload.IsEnabled = _model.CanEdit && _pickThemeImage is not null && !_pickingThemeImage; actions.Children.Add(upload);
        _themePicker.Children.Add(actions);
        if (_model.ThemeSource == FileStationThemeImageSource.Nas)
        {
            _themePicker.Children.Add(Label(_model.ThemeFolder.Length == 0 ? T("FsThemeSharedFolders") : _model.ThemeFolder));
            var up = Button("FsThemeUp", async () => await _model.NavigateThemeFolderAsync(up: true)); up.IsEnabled = !_model.IsBusy && _model.ThemeFolder.Length > 0; _themePicker.Children.Add(up);
        }
        var filter = new TextBox { Header = T("FsThemeFilter"), Text = _model.ThemeFilter, IsEnabled = !_model.IsBusy };
        AutomationProperties.SetAutomationId(filter, "FsThemeFilter"); filter.TextChanged += (_, _) => { if (!_rendering) _model.SetThemeFilter(filter.Text); }; _themePicker.Children.Add(filter);
        if (!_themeListInitialized)
        {
            _themeListInitialized = true; AutomationProperties.SetName(_themeList, T("FsThemeImages"));
            _themeList.ItemClick += async (_, args) => {
                if (args.ClickedItem is not ListViewItem row || _model.IsBusy) return;
                if (row.Tag is FileItem { IsDirectory: true } directory) await _model.NavigateThemeFolderAsync(directory);
                else if (row.Tag is FileItem file) await _model.PreviewThemeFileAsync(file);
                else if (row.Tag is FileStationThemeImage image) await _model.PreviewThemeImageAsync(image);
            };
        }
        RenderThemeList(); _themePicker.Children.Add(_themeList); _themePicker.Children.Add(_themeEmpty);
        if (_model.ThemePreview is { } bytes && _model.ThemeSelection is { } selected)
        {
            var image = new Image { Height = 140, Stretch = Stretch.Uniform, HorizontalAlignment = HorizontalAlignment.Stretch };
            AutomationProperties.SetName(image, _text.Format("FsThemePreview", selected.Name)); _themePicker.Children.Add(image);
            _ = SetThemePreviewAsync(image, bytes, _themePreviewGeneration);
        }
        var back = Button("FsThemeBack", _model.CloseThemePicker); back.IsEnabled = !_model.IsBusy && !_pickingThemeImage; _themePicker.Children.Add(back);
    }
    private void RenderThemeList()
    {
        _themeList.Items.Clear();
        if (_model.ThemeSource == FileStationThemeImageSource.Nas)
            foreach (var item in _model.VisibleThemeFiles)
            {
                var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 }; panel.Children.Add(new SymbolIcon(item.IsDirectory ? Symbol.Folder : Symbol.Pictures)); panel.Children.Add(Label(item.Name));
                _themeList.Items.Add(new ListViewItem { Content = panel, Tag = item });
            }
        else foreach (var item in _model.VisibleThemeImages)
        {
            var name = item.Source == FileStationThemeImageSource.Default ? _text.Format("FsThemeDefaultName", FileStationThemeImage.Defaults.ToList().FindIndex(v => v.Path == item.Path) + 1) : item.Name;
            _themeList.Items.Add(new ListViewItem { Content = Label(name), Tag = item });
        }
        _themeList.IsEnabled = !_model.IsBusy; _themeEmpty.Visibility = Show(!_model.IsBusy && _model.ThemeMessageKey is null && _themeList.Items.Count == 0);
        _themeEmpty.Text = T(_model.ThemeFilter.Length > 0 ? "FsThemeFilteredEmpty" : _model.ThemeSource == FileStationThemeImageSource.History ? "FsThemeHistoryEmpty" : "FsThemeFolderEmpty");
    }
    private async Task SetThemePreviewAsync(Image target, byte[] bytes, long generation)
    {
        try
        {
            using var stream = new MemoryStream(bytes, false); using var random = stream.AsRandomAccessStream();
            var bitmap = new BitmapImage { DecodePixelWidth = 480 }; await bitmap.SetSourceAsync(random);
            if (!_disposed && generation == _themePreviewGeneration) target.Source = bitmap;
        }
        catch { /* Repository 已解码校验；窗口关闭或显示器解码失败不会提交任何设置。 */ }
    }
    private async void UploadThemeImage()
    {
        if (_pickThemeImage is null || _pickingThemeImage || !_model.CanEdit) return;
        var kind = _model.ThemeKind; _themeLocalReadFailed = false; _pickingThemeImage = true; Render();
        try
        {
            var path = await _pickThemeImage(); if (_disposed || path is null || !_model.ThemePickerOpen || _model.ThemeKind != kind) return;
            var bytes = await File.ReadAllBytesAsync(path); if (_disposed || !_model.ThemePickerOpen || _model.ThemeKind != kind) return;
            await _model.UploadThemeImageAsync(Path.GetFileName(path), bytes);
        }
        catch
        {
            if (!_disposed) _themeLocalReadFailed = true;
        }
        finally { _pickingThemeImage = false; if (!_disposed) Render(); }
    }
}
