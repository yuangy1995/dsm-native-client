using System.ComponentModel;
using LanStash.App.Features.Downloads;
using LanStash.App.Features.Files.CopyMove;
using LanStash.App.Localization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Automation;

namespace LanStash.App.Views;

public sealed partial class DownloadCreateOptionsDialogContent : UserControl, IDisposable
{
    private readonly DownloadCreateOptionsViewModel _model;
    private readonly LocalizationService _l = LocalizationService.Current;
    private bool _rendering, _sending;
    internal event Action? StateChanged;
    internal Style ActionButtonStyle => (Style)Resources["CreateOptionButtonStyle"];
    internal bool CanSubmit => !_sending && !_model.IsLoading && !_model.IsBrowsing;
    internal DownloadCreateOptionsDialogContent(DownloadCreateOptionsViewModel model, string fileName, bool taskFile = true)
    {
        InitializeComponent(); _model = model; FileNameText.Text = fileName;
        FileNameText.Visibility = taskFile ? Visibility.Visible : Visibility.Collapsed;
        ArchivePassword.Visibility = PasswordHint.Visibility = taskFile ? Visibility.Visible : Visibility.Collapsed;
        BrowseButton.Content = _l.Get("DownloadSettingsBrowse"); DefaultButton.Content = _l.Get("DownloadCreateUseDefault");
        UpButton.Content = _l.Get("DownloadSettingsFolderUp"); OpenButton.Content = _l.Get("DownloadSettingsFolderOpen");
        ChooseButton.Content = _l.Get("DownloadSettingsFolderChoose"); CancelBrowseButton.Content = _l.Get("DownloadSettingsFolderClose");
        EmptyText.Text = _l.Get("DownloadSettingsFoldersEmpty"); ArchivePassword.Header = _l.Get("DownloadCreateUnzipPassword");
        PasswordHint.Text = _l.Get("DownloadCreatePasswordHint"); AutomationProperties.SetName(FolderList, _l.Get("DownloadSettingsBrowse"));
        _model.PropertyChanged += ModelChanged; Render();
    }
    internal string? TakePassword() { var value = ArchivePassword.Password; ArchivePassword.Password = ""; return value.Length == 0 ? null : value; }
    internal void BeginSubmission() { _sending = true; ArchivePassword.Password = ""; Render(); }
    private void ModelChanged(object? sender, PropertyChangedEventArgs e) => Render();
    private void Render()
    {
        if (_rendering) return; _rendering = true;
        DestinationText.Text = _model.Destination is { } destination ? _l.Format("DownloadStationCreateDestinationText", destination) : _l.Get("DownloadCreateNasDefault");
        BrowseButton.Visibility = _model.CanBrowse ? Visibility.Visible : Visibility.Collapsed;
        BrowseButton.IsEnabled = DefaultButton.IsEnabled = ArchivePassword.IsEnabled = !_sending;
        FolderPanel.Visibility = _model.IsBrowsing ? Visibility.Visible : Visibility.Collapsed;
        FolderPathText.Text = _model.CurrentPath.Length == 0 ? _l.Get("DownloadSettingsFolderRoot") : _model.CurrentPath;
        FolderLoading.IsActive = _model.IsLoading; FolderLoading.Visibility = _model.IsLoading ? Visibility.Visible : Visibility.Collapsed;
        if (!ReferenceEquals(FolderList.ItemsSource, _model.Folders)) FolderList.ItemsSource = _model.Folders;
        FolderList.IsEnabled = !_model.IsLoading;
        OpenButton.IsEnabled = !_model.IsLoading && FolderList.SelectedItem is FileCopyMoveFolder;
        ChooseButton.IsEnabled = !_model.IsLoading && FolderList.SelectedItem is FileCopyMoveFolder { CanWrite: true };
        UpButton.IsEnabled = !_model.IsLoading && _model.CurrentPath.Length > 0;
        ErrorText.Text = _model.ErrorKey is { } error ? _l.Get(error) : ""; ErrorText.Visibility = _model.ErrorKey is null ? Visibility.Collapsed : Visibility.Visible;
        EmptyText.Visibility = !_model.IsLoading && _model.ErrorKey is null && _model.Folders.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        SendingProgress.IsActive = _sending; SendingProgress.Visibility = _sending ? Visibility.Visible : Visibility.Collapsed;
        _rendering = false; StateChanged?.Invoke();
    }
    private async void Browse_Click(object sender, RoutedEventArgs e) => await _model.BrowseAsync("");
    private void Default_Click(object sender, RoutedEventArgs e) => _model.UseDefault();
    private void Selection_Changed(object sender, SelectionChangedEventArgs e) => Render();
    private async void Open_Click(object sender, RoutedEventArgs e) { if (FolderList.SelectedItem is FileCopyMoveFolder folder) await _model.BrowseAsync(folder.Path); }
    private void Choose_Click(object sender, RoutedEventArgs e) { if (FolderList.SelectedItem is FileCopyMoveFolder folder) _model.Choose(folder); }
    private void CloseBrowser_Click(object sender, RoutedEventArgs e) => _model.CloseBrowser();
    private async void Up_Click(object sender, RoutedEventArgs e) { var path = _model.CurrentPath.TrimEnd('/'); var index = path.LastIndexOf('/'); await _model.BrowseAsync(index <= 0 ? "" : path[..index]); }
    public void Dispose() { _model.PropertyChanged -= ModelChanged; ArchivePassword.Password = ""; }
}
