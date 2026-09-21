using LanStash.App.Features.Files.CopyMove;
using LanStash.App.ViewModels;

namespace LanStash.App.Features.Downloads;

/// <summary>创建任务的目录选择；密码不进入此状态对象。</summary>
internal sealed class DownloadCreateOptionsViewModel(IFileCopyMoveFolderSource? folders) : ObservableObject, IDisposable
{
    private CancellationTokenSource? _load;
    private long _generation;
    private bool _disposed;
    public bool CanBrowse => folders is not null;
    public bool IsBrowsing { get; private set; }
    public bool IsLoading { get; private set; }
    public string? Destination { get; private set; }
    public string CurrentPath { get; private set; } = "";
    public string? ErrorKey { get; private set; }
    public IReadOnlyList<FileCopyMoveFolder> Folders { get; private set; } = [];
    public async Task BrowseAsync(string path)
    {
        if (_disposed || folders is null) return;
        _load?.Cancel(); _load?.Dispose(); _load = new(); var token = _load.Token; var generation = ++_generation;
        IsBrowsing = true; IsLoading = true; ErrorKey = null; Folders = []; Changed();
        try
        {
            var result = await folders.LoadFoldersAsync(path, token);
            if (_disposed || token.IsCancellationRequested || generation != _generation) return;
            CurrentPath = path; Folders = result;
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        catch { if (!_disposed && generation == _generation) ErrorKey = "DownloadSettingsFoldersFailed"; }
        finally { if (!_disposed && generation == _generation) { IsLoading = false; Changed(); } }
    }
    public void Choose(FileCopyMoveFolder value)
    {
        if (_disposed || IsLoading || !Folders.Contains(value) || !value.CanWrite || folders?.IsReadOnlyPath(value.Path) != false) return;
        Destination = value.Path.Trim('/'); CloseBrowser();
    }
    public void UseDefault() { Destination = null; CloseBrowser(); }
    public void CloseBrowser() { _generation++; _load?.Cancel(); IsBrowsing = false; IsLoading = false; Folders = []; Changed(); }
    private void Changed() { if (!_disposed) RaisePropertyChanged(string.Empty); }
    public void Dispose() { if (_disposed) return; _disposed = true; CloseBrowser(); _load?.Dispose(); _load = null; Destination = null; }
}
