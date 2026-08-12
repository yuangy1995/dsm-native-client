using System.Buffers;

namespace LanStash.Infrastructure.Transport;

/// <summary>
/// 提供背压的固定容量内存环形缓冲区：
/// 缓冲区已满时 <see cref="WriteAsync"/> 阻塞，
/// 缓冲区为空时 <see cref="ReadAsync"/> 阻塞。
///
/// 用于单写入者、单读取者管道。
/// 线程安全并支持取消。
/// </summary>
public sealed class BoundedMemoryStream : IDisposable
{
    private readonly byte[] _buffer;
    private readonly int _capacity;
    private readonly object _gate = new();
    private int _head;
    private int _tail;
    private int _available;
    private bool _writeComplete;
    private bool _cancelled;
    private Exception? _fault;
    private bool _disposed;
    private readonly CancellationTokenSource _internalCts = new();

    public BoundedMemoryStream(int capacity = 12 * 1024 * 1024)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(capacity, 1);
        _capacity = capacity;
        _buffer = ArrayPool<byte>.Shared.Rent(capacity);
    }

    public int Capacity => _capacity;

    public bool IsReadComplete
    {
        get
        {
            lock (_gate)
            {
                return _writeComplete && _available == 0 && !_cancelled;
            }
        }
    }

    public async Task WriteAsync(ReadOnlyMemory<byte> data, CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(
            cancellationToken, _internalCts.Token);
        var token = linked.Token;
        var offset = 0;
        var remaining = data.Length;

        while (remaining > 0)
        {
            token.ThrowIfCancellationRequested();

            int written;
            lock (_gate)
            {
                while (_available == _capacity && !_writeComplete && !_cancelled)
                {
                    if (!Monitor.Wait(_gate, TimeSpan.FromMilliseconds(500)))
                        token.ThrowIfCancellationRequested();
                }

                if (_cancelled) ThrowFaultOrCancelled();
                if (_writeComplete)
                    throw new InvalidOperationException(
                        "Cannot write after CompleteWrite has been called.");

                var toWrite = Math.Min(remaining, _capacity - _available);
                var firstPart = Math.Min(toWrite, _capacity - _head);
                data.Span.Slice(offset, firstPart).CopyTo(_buffer.AsSpan(_head, firstPart));
                _head = (_head + firstPart) % _capacity;
                written = firstPart;

                if (toWrite > firstPart)
                {
                    var wrapBytes = toWrite - firstPart;
                    data.Span.Slice(offset + firstPart, wrapBytes)
                        .CopyTo(_buffer.AsSpan(0, wrapBytes));
                    _head = wrapBytes;
                    written += wrapBytes;
                }

                _available += written;
                Monitor.PulseAll(_gate);
            }

            offset += written;
            remaining -= written;
        }
    }

    public async Task<int> ReadAsync(Memory<byte> destination, CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(
            cancellationToken, _internalCts.Token);
        var token = linked.Token;

        lock (_gate)
        {
            while (_available == 0 && !_writeComplete && !_cancelled)
            {
                if (!Monitor.Wait(_gate, TimeSpan.FromMilliseconds(500)))
                    token.ThrowIfCancellationRequested();
            }

            if (_cancelled) ThrowFaultOrCancelled();
            if (_available == 0 && _writeComplete) return 0;

            var toRead = Math.Min(destination.Length, _available);
            var firstPart = Math.Min(toRead, _capacity - _tail);
            _buffer.AsSpan(_tail, firstPart).CopyTo(destination.Span);
            _tail = (_tail + firstPart) % _capacity;
            var read = firstPart;

            if (toRead > firstPart)
            {
                var wrapBytes = toRead - firstPart;
                _buffer.AsSpan(0, wrapBytes).CopyTo(destination.Span.Slice(firstPart));
                _tail = wrapBytes;
                read += wrapBytes;
            }

            _available -= read;
            Monitor.PulseAll(_gate);
            return read;
        }
    }

    public void CompleteWrite()
    {
        ThrowIfDisposed();
        lock (_gate)
        {
            _writeComplete = true;
            Monitor.PulseAll(_gate);
        }
    }

    public void Cancel(Exception? fault = null)
    {
        lock (_gate)
        {
            if (_cancelled) return;
            _cancelled = true;
            _fault = fault;
            Monitor.PulseAll(_gate);
        }
        _internalCts.Cancel();
    }

    private void ThrowFaultOrCancelled()
    {
        if (_fault is not null)
            throw new IOException("The bounded memory pipe was faulted.", _fault);
        throw new OperationCanceledException("The bounded memory pipe was cancelled.");
    }

    private void ThrowIfDisposed()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        Cancel();
        _internalCts.Dispose();
        ArrayPool<byte>.Shared.Return(_buffer);
    }
}
