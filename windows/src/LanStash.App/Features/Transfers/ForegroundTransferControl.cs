namespace LanStash.App.Features.Transfers;

/// <summary>暂停保留原请求和下载暂存内容；继续只释放读取，不创建重试请求。</summary>
internal sealed class ForegroundTransferControl
{
    private readonly object _sync = new();
    private TaskCompletionSource? _resume;

    public bool IsPaused { get { lock (_sync) return _resume is not null; } }

    public void Pause()
    {
        lock (_sync) _resume ??= new(TaskCreationOptions.RunContinuationsAsynchronously);
    }

    public void Resume()
    {
        TaskCompletionSource? resume;
        lock (_sync) { resume = _resume; _resume = null; }
        resume?.TrySetResult();
    }

    public async ValueTask WaitAsync(CancellationToken cancellationToken)
    {
        while (true)
        {
            cancellationToken.ThrowIfCancellationRequested();
            Task? wait;
            lock (_sync) wait = _resume?.Task;
            if (wait is null) return;
            await wait.WaitAsync(cancellationToken).ConfigureAwait(false);
        }
    }
}

/// <summary>上传仍使用同一个不可重放的 multipart 请求；服务器超时交回原有未知结果流程。</summary>
internal sealed class ForegroundTransferReadStream(Stream source, ForegroundTransferControl control) : Stream
{
    public override bool CanRead => source.CanRead;
    public override bool CanSeek => source.CanSeek;
    public override bool CanWrite => false;
    public override long Length => source.Length;
    public override long Position { get => source.Position; set => source.Position = value; }
    public override long Seek(long offset, SeekOrigin origin) => source.Seek(offset, origin);
    public override int Read(byte[] buffer, int offset, int count)
    {
        control.WaitAsync(CancellationToken.None).AsTask().GetAwaiter().GetResult();
        return source.Read(buffer, offset, count);
    }
    public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
    {
        await control.WaitAsync(cancellationToken).ConfigureAwait(false);
        return await source.ReadAsync(buffer, cancellationToken).ConfigureAwait(false);
    }
    public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken) =>
        ReadAsync(buffer.AsMemory(offset, count), cancellationToken).AsTask();
    public override void Flush() => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException();
    public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    protected override void Dispose(bool disposing) { if (disposing) source.Dispose(); base.Dispose(disposing); }
    public override ValueTask DisposeAsync() => source.DisposeAsync();
}
