using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.Files.DirectorySize;

public enum FileDirectorySizeState
{
    Ready,
    Calculating,
    Available,
    Error,
    Unsupported,
    Cancelled,
}

public sealed class FileDirectorySizeViewModel : ObservableObject, IDisposable
{
    private readonly IDirectorySizeRepository _repository;
    private readonly FileItem _folder;
    private CancellationTokenSource? _cancellation;
    private Task? _calculation;
    private FileDirectorySizeState _state;
    private DirectorySizeResult? _summary;
    private bool _disposed;
    private long _generation;

    public FileDirectorySizeViewModel(
        IDirectorySizeRepository repository,
        Guid profileId,
        FileItem folder)
    {
        ArgumentNullException.ThrowIfNull(repository);
        ArgumentNullException.ThrowIfNull(folder);
        if (repository.ProfileId != profileId)
        {
            throw new ArgumentException("file.dirsize.profile-mismatch", nameof(repository));
        }
        if (!folder.IsDirectory)
        {
            throw new ArgumentException("file.dirsize.folder-required", nameof(folder));
        }
        _repository = repository;
        _folder = folder;
        _state = repository.Availability.IsAvailable
            ? FileDirectorySizeState.Ready
            : FileDirectorySizeState.Unsupported;
    }

    public FileItem Folder => _folder;

    public FileDirectorySizeState State
    {
        get => _state;
        private set
        {
            if (SetProperty(ref _state, value))
            {
                RaisePropertyChanged(nameof(CanCalculate));
                RaisePropertyChanged(nameof(CanCancel));
            }
        }
    }

    public DirectorySizeResult? Summary
    {
        get => _summary;
        private set => SetProperty(ref _summary, value);
    }

    public bool CanCalculate => State is FileDirectorySizeState.Ready or
        FileDirectorySizeState.Available or FileDirectorySizeState.Error or
        FileDirectorySizeState.Cancelled;

    public bool CanCancel => State == FileDirectorySizeState.Calculating;

    public Task CalculateAsync()
    {
        ThrowIfDisposed();
        if (!CanCalculate)
        {
            return Task.CompletedTask;
        }

        CancelCurrent();
        _calculation = CalculateCoreAsync();
        return _calculation;
    }

    private async Task CalculateCoreAsync()
    {
        var generation = ++_generation;
        var cancellation = new CancellationTokenSource();
        _cancellation = cancellation;
        State = FileDirectorySizeState.Calculating;
        try
        {
            var summary = await _repository.CalculateDirectorySizeAsync(
                _folder.Path,
                cancellation.Token);
            if (!IsCurrent(generation))
            {
                return;
            }
            Summary = summary;
            State = FileDirectorySizeState.Available;
        }
        catch (OperationCanceledException)
        {
            if (IsCurrent(generation))
            {
                State = FileDirectorySizeState.Cancelled;
            }
        }
        catch
        {
            if (IsCurrent(generation))
            {
                State = FileDirectorySizeState.Error;
            }
        }
        finally
        {
            if (ReferenceEquals(_cancellation, cancellation))
            {
                _cancellation = null;
            }
            cancellation.Dispose();
        }
    }

    public void Cancel()
    {
        ThrowIfDisposed();
        if (CanCancel)
        {
            _cancellation?.Cancel();
        }
    }

    public async Task CancelAndWaitAsync()
    {
        if (_disposed)
        {
            return;
        }
        Cancel();
        if (_calculation is { } calculation)
        {
            try
            {
                await calculation.ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
            }
        }
    }

    private bool IsCurrent(long generation) => !_disposed && generation == _generation;

    private void CancelCurrent()
    {
        _cancellation?.Cancel();
        _cancellation?.Dispose();
        _cancellation = null;
    }

    private void ThrowIfDisposed() => ObjectDisposedException.ThrowIf(_disposed, this);

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
        _generation++;
        CancelCurrent();
    }
}
