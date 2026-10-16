using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.Files.Locations;

public sealed class FileVfsBrowserViewModel(IFileVfsBrowserRepository repository, FileVfsProfile profile) : ObservableObject, IDisposable
{
    private readonly CancellationTokenSource _lifetime = new();
    private readonly List<(string Path, string Name)> _parents = [];
    private bool _disposed;
    private int _generation;
    public FileVfsProfile Profile => profile;
    public string Path { get; private set; } = FileVfsPath.Root(profile);
    public string Location => _parents.Count == 0 ? profile.Alias : string.Join(" / ", new[] { profile.Alias }.Concat(_parents.Select(p => p.Name)));
    public IReadOnlyList<FileItem> Items { get; private set; } = [];
    public FileItem? Selected { get; private set; }
    public string Filter { get; private set; } = "";
    public FileListSortField Sort { get; private set; }
    public bool IsBusy { get; private set; }
    public bool HasError { get; private set; }
    public bool DownloadFailed { get; private set; }
    public bool DownloadStarted { get; private set; }
    public bool CanUp => !_disposed && !IsBusy && _parents.Count > 0;
    public bool CanOpen => !_disposed && !IsBusy && !HasError && Selected?.IsDirectory == true;
    public bool CanDownload => !_disposed && !IsBusy && !HasError && repository.CanDownloadVfs && Selected is { IsDirectory: false, Size: >= 0 };
    public IEnumerable<FileItem> VisibleItems
    {
        get
        {
            var filtered = Items.Where(f => f.Name.Contains(Filter, StringComparison.CurrentCultureIgnoreCase));
            return Sort switch
            {
                FileListSortField.Size => filtered.OrderByDescending(f => f.IsDirectory).ThenByDescending(f => f.Size).ThenBy(f => f.Name, StringComparer.CurrentCultureIgnoreCase),
                FileListSortField.ModifiedTime => filtered.OrderByDescending(f => f.IsDirectory).ThenByDescending(f => f.ModifiedAt).ThenBy(f => f.Name, StringComparer.CurrentCultureIgnoreCase),
                _ => filtered.OrderByDescending(f => f.IsDirectory).ThenBy(f => f.Name, StringComparer.CurrentCultureIgnoreCase),
            };
        }
    }
    public void SetFilter(string value) { Filter = value; Selected = null; Notify(); }
    public void SetSort(FileListSortField value) { Sort = value; Notify(); }
    public void Select(FileItem? item) { if (_disposed || IsBusy) return; Selected = item is not null && VisibleItems.Contains(item) ? item : null; DownloadFailed = DownloadStarted = false; Notify(); }
    public Task LoadAsync() => LoadPathAsync(Path);
    public async Task OpenAsync()
    {
        if (!CanOpen || Selected is not { } item) return;
        _parents.Add((Path, item.Name)); Filter = "";
        await LoadPathAsync(item.Path);
    }
    public async Task UpAsync()
    {
        if (!CanUp) return;
        var path = _parents[^1].Path; _parents.RemoveAt(_parents.Count - 1); Filter = "";
        await LoadPathAsync(path);
    }
    private async Task LoadPathAsync(string path)
    {
        if (_disposed || IsBusy) return;
        var generation = ++_generation;
        Path = path; Items = []; Selected = null; HasError = DownloadFailed = DownloadStarted = false; IsBusy = true; Notify();
        try
        {
            var folder = await repository.ListVfsFolderAsync(profile, path, _lifetime.Token);
            if (_disposed || generation != _generation) return;
            if (folder.Profile != profile || folder.Path != path) throw new InvalidOperationException("file.vfs.changed");
            Items = folder.Items;
        }
        catch (Exception) { if (!_disposed && generation == _generation) { Items = []; HasError = true; } }
        finally { if (!_disposed && generation == _generation) { IsBusy = false; Notify(); } }
    }
    public async Task DownloadAsync(Func<FileVfsDownloadSource, Func<bool>, CancellationToken, Task<bool>> start)
    {
        if (!CanDownload || Selected is not { } item) return;
        var source = new FileVfsDownloadSource(profile, Path, item); var generation = _generation;
        IsBusy = true; DownloadFailed = DownloadStarted = false; Notify();
        try
        {
            var started = await start(source, () => !_disposed && generation == _generation, _lifetime.Token);
            if (!_disposed && generation == _generation) DownloadStarted = started;
        }
        catch (Exception) { if (!_disposed && generation == _generation) DownloadFailed = true; }
        finally { if (!_disposed && generation == _generation) { IsBusy = false; Notify(); } }
    }
    private void Notify() => RaisePropertyChanged(string.Empty);
    public void Dispose() { if (_disposed) return; _disposed = true; _generation++; _lifetime.Cancel(); _lifetime.Dispose(); Items = []; Selected = null; }
}
