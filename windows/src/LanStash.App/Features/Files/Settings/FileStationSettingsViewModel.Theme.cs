using LanStash.Domain;

namespace LanStash.App.Features.Files.Settings;

public sealed partial class FileStationSettingsViewModel
{
    public bool ThemePickerOpen { get; private set; }
    public FileStationThemeImageKind ThemeKind { get; private set; }
    public FileStationThemeImageSource ThemeSource { get; private set; }
    public IReadOnlyList<FileStationThemeImage> ThemeImages { get; private set; } = [];
    public IReadOnlyList<FileItem> ThemeFiles { get; private set; } = [];
    public string ThemeFolder { get; private set; } = "";
    public string ThemeFilter { get; private set; } = "";
    public FileStationThemeImage? ThemeSelection { get; private set; }
    public byte[]? ThemePreview { get; private set; }
    public string? ThemeMessageKey { get; private set; }
    public bool CanUseThemeImage => !_disposed && CanEdit && ThemePickerOpen && ThemeSelection is not null && ThemePreview is not null;
    public IEnumerable<FileStationThemeImage> VisibleThemeImages => ThemeImages.Where(v => v.Name.Contains(ThemeFilter, StringComparison.CurrentCultureIgnoreCase));
    public IEnumerable<FileItem> VisibleThemeFiles => ThemeFiles.Where(v => v.Name.Contains(ThemeFilter, StringComparison.CurrentCultureIgnoreCase));

    public async Task OpenThemePickerAsync(FileStationThemeImageKind kind)
    {
        if (!CanEdit || Draft is not FileStationTheme || repository is not IFileStationThemeRepository || !Enum.IsDefined(kind)) return;
        ThemePickerOpen = true; ThemeKind = kind; ThemeSource = FileStationThemeImageSource.History; ThemeFolder = ""; ThemeFilter = "";
        await LoadThemeImagesAsync();
    }
    public void CloseThemePicker()
    {
        if (IsBusy) return; ThemePickerOpen = false; ThemeImages = []; ThemeFiles = []; ThemeSelection = null; ThemePreview = null; ThemeMessageKey = null; Notify();
    }
    public async Task SetThemeSourceAsync(FileStationThemeImageSource source)
    {
        if (!ThemePickerOpen || IsBusy || !Enum.IsDefined(source) || source == FileStationThemeImageSource.Default && ThemeKind != FileStationThemeImageKind.Background) return;
        ThemeSource = source; ThemeFilter = ""; await LoadThemeImagesAsync();
    }
    public void SetThemeFilter(string filter) { if (_disposed) return; ThemeFilter = filter; RaisePropertyChanged(nameof(ThemeFilter)); }
    public async Task NavigateThemeFolderAsync(FileItem? directory = null, bool up = false)
    {
        if (!ThemePickerOpen || IsBusy || ThemeSource != FileStationThemeImageSource.Nas) return;
        if (up) ThemeFolder = ThemeFolder.Contains('/') ? ThemeFolder[..ThemeFolder.LastIndexOf('/')] : "";
        else if (directory is { IsDirectory: true } && ThemeFiles.Contains(directory)) ThemeFolder = directory.Path;
        else return;
        ThemeFilter = ""; await LoadThemeImagesAsync();
    }
    public async Task LoadThemeImagesAsync()
    {
        if (_disposed || IsBusy || !ThemePickerOpen || repository is not IFileStationThemeRepository theme) return;
        IsBusy = true; ThemeImages = []; ThemeFiles = []; ThemeSelection = null; ThemePreview = null; ThemeMessageKey = null; Notify();
        try
        {
            IReadOnlyList<FileStationThemeImage> images = []; IReadOnlyList<FileItem> files = [];
            if (ThemeSource == FileStationThemeImageSource.History) images = await theme.ListFileStationThemeImagesAsync(ThemeKind, _lifetime.Token);
            else if (ThemeSource == FileStationThemeImageSource.Default) images = FileStationThemeImage.Defaults;
            else if (repository is IDsmRepository browser)
            {
                var all = new List<FileItem>(); var paths = new HashSet<string>(StringComparer.Ordinal); int? expected = null;
                for (var offset = 0; ;)
                {
                    var page = await browser.ListFilesAsync(ThemeFolder, offset, 200, FileListOptions.Default, _lifetime.Token);
                    if (page.Offset != offset || page.Total < offset || expected.HasValue && expected != page.Total || page.Items.Count > 200 ||
                        page.Items.Count > page.Total - offset || page.Items.Count == 0 && page.Total != offset) throw new InvalidDataException("file.theme.folder.changed");
                    expected = page.Total;
                    foreach (var item in page.Items)
                    {
                        if (!paths.Add(item.Path) || item.Path != ThemeFolder + "/" + item.Name || item.Name is "" or "." or ".." || item.Name.Contains('/') || item.Name.Contains('\\'))
                            throw new InvalidDataException("file.theme.folder.invalid");
                        if (item.IsDirectory || FileStationThemeImage.SupportsFilename(item.Name)) all.Add(item);
                    }
                    offset += page.Items.Count; if (offset == page.Total) break;
                }
                files = all;
            }
            else throw new NotSupportedException();
            if (_disposed) return; ThemeImages = images; ThemeFiles = files;
        }
        catch { if (!_disposed) ThemeMessageKey = "FsThemeLoadFailed"; }
        finally { if (!_disposed) { IsBusy = false; Notify(); } }
    }
    public Task PreviewThemeFileAsync(FileItem file) => ThemeSource == FileStationThemeImageSource.Nas && ThemeFiles.Contains(file) && !file.IsDirectory
        ? PreviewThemeImageAsync(new(ThemeKind, FileStationThemeImageSource.Nas, file.Path, file.Name)) : Task.CompletedTask;
    public async Task PreviewThemeImageAsync(FileStationThemeImage image)
    {
        if (_disposed || IsBusy || !ThemePickerOpen || repository is not IFileStationThemeRepository theme || image.Kind != ThemeKind || image.Source != ThemeSource ||
            (image.Source == FileStationThemeImageSource.Nas ? !ThemeFiles.Any(f => !f.IsDirectory && f.Path == image.Path) : !ThemeImages.Contains(image))) return;
        IsBusy = true; ThemeSelection = null; ThemePreview = null; ThemeMessageKey = null; Notify();
        try { var bytes = await theme.ReadFileStationThemeImageAsync(image, _lifetime.Token); if (!_disposed) { ThemePreview = bytes; ThemeSelection = image; } }
        catch { if (!_disposed) ThemeMessageKey = "FsThemePreviewFailed"; }
        finally { if (!_disposed) { IsBusy = false; Notify(); } }
    }
    public void UseThemeImage()
    {
        if (!CanUseThemeImage || Draft is not FileStationTheme theme) return;
        UpdateDraft(ThemeKind == FileStationThemeImageKind.Logo ? theme with { CustomLogo = true, LogoImage = ThemeSelection } : theme with { CustomBackground = true, BackgroundImage = ThemeSelection });
        CloseThemePicker();
    }
    public async Task UploadThemeImageAsync(string filename, byte[] bytes)
    {
        if (_disposed || !CanEdit || !ThemePickerOpen || repository is not IFileStationThemeRepository theme) return;
        IsBusy = true; ThemeMessageKey = null; ThemePreview = null; ThemeSelection = null; Notify();
        try
        {
            var result = await theme.UploadFileStationThemeImageAsync(ThemeKind, filename, bytes, true, _lifetime.Token);
            if (_disposed) return;
            ThemeMessageKey = result.Outcome.Status switch {
                MutationResultStatus.ConfirmedSuccess => "FsThemeUploaded", MutationResultStatus.SubmittedButUnverified => "FsThemeUploadPending",
                MutationResultStatus.PermissionDenied => "FsSettingsDenied", MutationResultStatus.Unsupported => "FsSettingsUnsupported",
                MutationResultStatus.CancelledBeforeSubmission => "FsSettingsNotSent", _ => result.Outcome.ErrorCategory == MutationErrorCategory.Validation ? "FsThemeInvalidImage" : "FsThemeUploadFailed" };
            if (result.Image is { } image && result.Outcome.Status == MutationResultStatus.ConfirmedSuccess)
            {
                ThemeSource = FileStationThemeImageSource.History; ThemeFilter = ""; ThemeFiles = []; ThemeImages = [image];
                try { var preview = await theme.ReadFileStationThemeImageAsync(image, _lifetime.Token); if (!_disposed) { ThemePreview = preview; ThemeSelection = image; } }
                catch { if (!_disposed) ThemeMessageKey = "FsThemeUploadedPreviewFailed"; }
            }
        }
        catch { if (!_disposed) ThemeMessageKey = "FsThemeUploadPending"; }
        finally { if (!_disposed) { IsBusy = false; Notify(); } }
    }
}
