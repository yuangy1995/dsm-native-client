using System.Net.Http.Headers;
using System.Runtime.InteropServices.WindowsRuntime;
using LanStash.Domain;
using Windows.Foundation;
using Windows.Storage.Streams;

namespace LanStash.App.Features.Files.Preview;

/// <summary>
/// 为系统媒体栈提供只读随机访问。所有 clone 共享同一内容版本、首块缓存和取消边界。
/// </summary>
public sealed class StrictRangeMediaSource : IDisposable
{
    private readonly StrictRangeReadSession _session;
    private bool _disposed;

    private StrictRangeMediaSource(StrictRangeReadSession session, string contentType)
    {
        _session = session;
        Stream = new StrictRangeRandomAccessStream(session);
        ContentType = contentType;
    }

    public IRandomAccessStream Stream { get; }
    public string ContentType { get; }

    public static async Task<StrictRangeMediaSource> CreateAsync(
        IFileRangeReader repository,
        FileItem item,
        FilePreviewKind kind,
        CancellationToken cancellationToken)
    {
        if (item.Size <= 0 || kind is not (FilePreviewKind.Audio or FilePreviewKind.Video))
        {
            throw new InvalidOperationException("A known non-empty media file is required.");
        }

        var session = new StrictRangeReadSession(repository, item.Path, item.Size);
        try
        {
            await session.InitializeAsync(cancellationToken).ConfigureAwait(false);
            return new StrictRangeMediaSource(
                session,
                FilePreviewClassifier.MediaContentType(item, kind));
        }
        catch
        {
            session.Dispose();
            throw;
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
        Stream.Dispose();
        _session.Dispose();
    }
}

internal sealed class StrictRangeReadSession : IDisposable
{
    internal const int MaximumRangeLength = 4 * 1024 * 1024;
    private readonly IFileRangeReader _repository;
    private readonly string _remotePath;
    private readonly long _totalLength;
    private readonly CancellationTokenSource _lifetime = new();
    private readonly SemaphoreSlim _initialization = new(1, 1);
    private byte[]? _smallFileBytes;
    private long _initialOffset;
    private byte[]? _initialBytes;
    private string? _contentVersion;
    private bool _initialized;
    private bool _disposed;

    public StrictRangeReadSession(
        IFileRangeReader repository,
        string remotePath,
        long totalLength)
    {
        _repository = repository;
        _remotePath = remotePath;
        _totalLength = totalLength;
    }

    public ulong Size => checked((ulong)_totalLength);

    public Task InitializeAsync(CancellationToken cancellationToken) =>
        ReadInitialAsync(cancellationToken);

    public async Task<byte[]> ReadAsync(
        long offset,
        int requestedLength,
        CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (offset < 0 || offset > _totalLength)
        {
            throw new ArgumentOutOfRangeException(nameof(offset));
        }
        if (requestedLength <= 0 || offset == _totalLength)
        {
            return [];
        }

        var length = checked((int)Math.Min(
            Math.Min((long)requestedLength, MaximumRangeLength),
            _totalLength - offset));
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(
            cancellationToken,
            _lifetime.Token);

        await ReadInitialAsync(linked.Token).ConfigureAwait(false);
        if (_smallFileBytes is { } all)
        {
            return all.AsSpan(checked((int)offset), length).ToArray();
        }
        if (_initialBytes is { } initial &&
            offset >= _initialOffset &&
            offset + length <= _initialOffset + initial.Length)
        {
            return initial.AsSpan(checked((int)(offset - _initialOffset)), length).ToArray();
        }

        var result = await _repository.ReadFileRangeResultAsync(
            _remotePath,
            offset,
            length,
            expectedContentVersion: _contentVersion,
            expectedTotalLength: _totalLength,
            cancellationToken: linked.Token).ConfigureAwait(false);
        Validate(result, offset, length, _totalLength);
        if (!string.Equals(
                result.ServerContentVersion,
                _contentVersion,
                StringComparison.Ordinal))
        {
            throw ContractFailure(result, "The media content version changed.");
        }
        return result.Bytes;
    }

    private async Task ReadInitialAsync(CancellationToken cancellationToken)
    {
        if (_initialized)
        {
            return;
        }

        await _initialization.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (_initialized)
            {
                return;
            }
            using var linked = CancellationTokenSource.CreateLinkedTokenSource(
                cancellationToken,
                _lifetime.Token);
            var length = checked((int)Math.Min(_totalLength, MaximumRangeLength));
            var result = await _repository.ReadFileRangeResultAsync(
                _remotePath,
                0,
                length,
                expectedTotalLength: _totalLength,
                cancellationToken: linked.Token).ConfigureAwait(false);
            Validate(result, 0, length, _totalLength);

            if (_totalLength <= MaximumRangeLength)
            {
                _smallFileBytes = result.Bytes;
            }
            else
            {
                if (!result.CanSafelyReadInSegments || !IsStrongEntityTag(result.ServerContentVersion))
                {
                    throw ContractFailure(
                        result,
                        "A large media preview requires a strong content version.");
                }
                _contentVersion = result.ServerContentVersion;
                _initialOffset = 0;
                _initialBytes = result.Bytes;
            }
            _initialized = true;
        }
        finally
        {
            _initialization.Release();
        }
    }

    private static void Validate(
        FileRangeReadResult result,
        long offset,
        long length,
        long totalLength)
    {
        if (result.RequestedStart != offset ||
            result.RequestedLength != length ||
            result.ResponseStart != offset ||
            result.ResponseLength != length ||
            result.TotalLength != totalLength ||
            result.ActualByteCount != length ||
            result.Bytes.LongLength != length)
        {
            throw ContractFailure(result, "The media range did not match the requested bytes.");
        }
    }

    private static bool IsStrongEntityTag(string? value) =>
        value is not null &&
        EntityTagHeaderValue.TryParse(value, out var entityTag) &&
        entityTag is { IsWeak: false } &&
        !string.Equals(entityTag.Tag, "*", StringComparison.Ordinal);

    private static FileRangeContractException ContractFailure(
        FileRangeReadResult result,
        string message) => new(
            FileRangeContractFailure.UnsafeSegmentedRead,
            message,
            result.StatusCode);

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
        _lifetime.Cancel();
        // 初始化请求可能不响应取消；保留同步基元，避免其 finally 与 Dispose 竞争 Release。
        _smallFileBytes = null;
        _initialBytes = null;
        _contentVersion = null;
    }
}

internal sealed class StrictRangeRandomAccessStream : IRandomAccessStream
{
    private readonly StrictRangeReadCursor _cursor;

    public StrictRangeRandomAccessStream(StrictRangeReadSession session) =>
        _cursor = new StrictRangeReadCursor(session);

    private StrictRangeRandomAccessStream(StrictRangeReadCursor cursor) => _cursor = cursor;

    public bool CanRead => true;
    public bool CanWrite => false;
    public ulong Position => _cursor.Position;
    public ulong Size
    {
        get => _cursor.Size;
        set => throw new NotSupportedException();
    }

    public IInputStream GetInputStreamAt(ulong position)
    {
        if (position > Size)
        {
            throw new ArgumentOutOfRangeException(nameof(position));
        }
        return new StrictRangeInputStream(_cursor.Session, position);
    }

    public IOutputStream GetOutputStreamAt(ulong position) => throw new NotSupportedException();

    public void Seek(ulong position)
    {
        if (position > Size)
        {
            throw new ArgumentOutOfRangeException(nameof(position));
        }
        _cursor.Seek(position);
    }

    public IRandomAccessStream CloneStream() =>
        new StrictRangeRandomAccessStream(_cursor.Clone());

    public IAsyncOperationWithProgress<IBuffer, uint> ReadAsync(
        IBuffer buffer,
        uint count,
        InputStreamOptions options) => AsyncInfo.Run<IBuffer, uint>(async (token, progress) =>
    {
        var allowed = checked((int)Math.Min(count, (uint)StrictRangeReadSession.MaximumRangeLength));
        var bytes = await _cursor.ReadAsync(allowed, token).ConfigureAwait(false);
        progress.Report(checked((uint)bytes.Length));
        return bytes.AsBuffer();
    });

    public IAsyncOperationWithProgress<uint, uint> WriteAsync(IBuffer buffer) =>
        throw new NotSupportedException();

    public IAsyncOperation<bool> FlushAsync() => throw new NotSupportedException();

    public void Dispose() => _cursor.Dispose();
}

internal sealed class StrictRangeInputStream : IInputStream
{
    private readonly StrictRangeReadCursor _cursor;

    public StrictRangeInputStream(StrictRangeReadSession session, ulong position)
    {
        _cursor = new StrictRangeReadCursor(session, position);
    }

    public IAsyncOperationWithProgress<IBuffer, uint> ReadAsync(
        IBuffer buffer,
        uint count,
        InputStreamOptions options) => AsyncInfo.Run<IBuffer, uint>(async (token, progress) =>
    {
        var allowed = checked((int)Math.Min(count, (uint)StrictRangeReadSession.MaximumRangeLength));
        var bytes = await _cursor.ReadAsync(allowed, token).ConfigureAwait(false);
        progress.Report(checked((uint)bytes.Length));
        return bytes.AsBuffer();
    });

    public void Dispose() => _cursor.Dispose();
}

/// <summary>
/// 每个系统 stream/clone 拥有独立游标；会话只共享不可变版本和 Range 缓存。
/// </summary>
internal sealed class StrictRangeReadCursor : IDisposable
{
    private readonly object _gate = new();
    private readonly SemaphoreSlim _serial = new(1, 1);
    private CancellationTokenSource? _activeRead;
    private long _generation;
    private ulong _position;
    private bool _disposed;

    public StrictRangeReadCursor(StrictRangeReadSession session, ulong position = 0)
    {
        Session = session;
        _position = position;
    }

    internal StrictRangeReadSession Session { get; }
    public ulong Size => Session.Size;
    public ulong Position
    {
        get
        {
            lock (_gate)
            {
                return _position;
            }
        }
    }

    public StrictRangeReadCursor Clone()
    {
        lock (_gate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            return new StrictRangeReadCursor(Session, _position);
        }
    }

    public void Seek(ulong position)
    {
        lock (_gate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            _generation++;
            _activeRead?.Cancel();
            _position = position;
        }
    }

    public async Task<byte[]> ReadAsync(int requestedLength, CancellationToken cancellationToken)
    {
        CancellationTokenSource read;
        long generation;
        lock (_gate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            generation = ++_generation;
            _activeRead?.Cancel();
            read = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            _activeRead = read;
        }

        try
        {
            await _serial.WaitAsync(read.Token).ConfigureAwait(false);
            try
            {
                ulong offset;
                lock (_gate)
                {
                    if (_disposed || generation != _generation)
                    {
                        throw new OperationCanceledException(read.Token);
                    }
                    offset = _position;
                }

                var bytes = await Session.ReadAsync(
                    checked((long)offset),
                    requestedLength,
                    read.Token).ConfigureAwait(false);
                lock (_gate)
                {
                    if (_disposed || generation != _generation || read.IsCancellationRequested)
                    {
                        throw new OperationCanceledException(read.Token);
                    }
                    _position = offset + checked((uint)bytes.Length);
                }
                return bytes;
            }
            finally
            {
                _serial.Release();
            }
        }
        finally
        {
            lock (_gate)
            {
                if (ReferenceEquals(_activeRead, read))
                {
                    _activeRead = null;
                }
            }
            read.Dispose();
        }
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (_disposed)
            {
                return;
            }
            _disposed = true;
            _generation++;
            _activeRead?.Cancel();
        }
    }
}
