using LanStash.Infrastructure.Transport;

namespace LanStash.Tests.Files.CopyMove;

public sealed class BoundedMemoryStreamContractTests : IDisposable
{
    private BoundedMemoryStream? _pipe;

    public void Dispose()
    {
        _pipe?.Dispose();
    }

    [Fact]
    public void DefaultCapacityIs12MiB()
    {
        _pipe = new BoundedMemoryStream();
        Assert.Equal(12 * 1024 * 1024, _pipe.Capacity);
    }

    [Fact]
    public void CustomCapacityIsHonored()
    {
        _pipe = new BoundedMemoryStream(1024);
        Assert.Equal(1024, _pipe.Capacity);
    }

    [Fact]
    public void ZeroCapacityThrows()
    {
        Assert.Throws<ArgumentOutOfRangeException>(() => new BoundedMemoryStream(0));
    }

    [Fact]
    public async Task WriteThenReadProducesExactBytes()
    {
        _pipe = new BoundedMemoryStream(64 * 1024);
        var original = new byte[8192];
        new Random(42).NextBytes(original);

        var writeTask = _pipe.WriteAsync(original);
        await writeTask;

        _pipe.CompleteWrite();

        var destination = new byte[original.Length];
        var totalRead = 0;
        while (totalRead < destination.Length)
        {
            var read = await _pipe.ReadAsync(destination.AsMemory(totalRead));
            if (read == 0) break;
            totalRead += read;
        }

        Assert.Equal(original.Length, totalRead);
        Assert.Equal(original, destination);
    }

    [Fact]
    public async Task LargeDataOverCapacityFlowsThroughWithoutCorruption()
    {
        _pipe = new BoundedMemoryStream(64 * 1024);
        var original = new byte[256 * 1024];
        new Random(17).NextBytes(original);

        var writeTask = Task.Run(async () =>
        {
            await _pipe.WriteAsync(original);
            _pipe.CompleteWrite();
        });

        var destination = new byte[original.Length];
        var totalRead = 0;
        while (totalRead < destination.Length)
        {
            var read = await _pipe.ReadAsync(destination.AsMemory(totalRead));
            if (read == 0) break;
            totalRead += read;
        }

        await writeTask;
        Assert.Equal(original.Length, totalRead);
        Assert.Equal(original, destination);
    }

    [Fact]
    public async Task ReadBlocksUntilDataAvailable()
    {
        _pipe = new BoundedMemoryStream(1024);
        var readStarted = new TaskCompletionSource();
        var readCompleted = new TaskCompletionSource<int>();

        var reader = Task.Run(async () =>
        {
            readStarted.SetResult();
            var buffer = new byte[512];
            return await _pipe.ReadAsync(buffer);
        });

        await readStarted.Task;
        await Task.Delay(50);
        Assert.False(reader.IsCompleted, "Reader should block when no data is available.");

        await _pipe.WriteAsync(new byte[512]);
        var bytesRead = await reader;
        Assert.Equal(512, bytesRead);
    }

    [Fact]
    public async Task WriteBlocksWhenBufferIsFull()
    {
        _pipe = new BoundedMemoryStream(512);
        // 填满缓冲区。
        await _pipe.WriteAsync(new byte[512]);

        var writeStarted = new TaskCompletionSource();
        var writer = Task.Run(async () =>
        {
            writeStarted.SetResult();
            await _pipe.WriteAsync(new byte[256]);
        });

        await writeStarted.Task;
        await Task.Delay(50);
        Assert.False(writer.IsCompleted, "Writer should block when buffer is full.");

        // 读取数据以腾出空间。
        var readBuffer = new byte[256];
        await _pipe.ReadAsync(readBuffer);

        await writer;
        Assert.True(writer.IsCompletedSuccessfully);
    }

    [Fact]
    public async Task CompleteWriteAllowsReaderToFinish()
    {
        _pipe = new BoundedMemoryStream(1024);
        await _pipe.WriteAsync(new byte[32]);
        _pipe.CompleteWrite();

        var readBuffer = new byte[128];
        var first = await _pipe.ReadAsync(readBuffer);
        Assert.Equal(32, first);

        var second = await _pipe.ReadAsync(readBuffer);
        Assert.Equal(0, second);

        Assert.True(_pipe.IsReadComplete);
    }

    [Fact]
    public async Task ZeroLengthWriteDoesNotInventData()
    {
        _pipe = new BoundedMemoryStream(1024);
        await _pipe.WriteAsync(ReadOnlyMemory<byte>.Empty);
        _pipe.CompleteWrite();

        var read = await _pipe.ReadAsync(new byte[16]);

        Assert.Equal(0, read);
        Assert.True(_pipe.IsReadComplete);
    }

    [Fact]
    public async Task CancelUnblocksPendingRead()
    {
        _pipe = new BoundedMemoryStream(1024);

        var reader = Task.Run(async () =>
        {
            var buffer = new byte[64];
            return await _pipe.ReadAsync(buffer);
        });

        await Task.Delay(50);
        _pipe.Cancel();

        await Assert.ThrowsAsync<OperationCanceledException>(() => reader);
    }

    [Fact]
    public async Task CancelUnblocksPendingWrite()
    {
        _pipe = new BoundedMemoryStream(512);
        await _pipe.WriteAsync(new byte[512]);

        var writer = Task.Run(async () =>
        {
            await _pipe.WriteAsync(new byte[256]);
        });

        await Task.Delay(50);
        _pipe.Cancel();

        await Assert.ThrowsAsync<OperationCanceledException>(() => writer);
    }

    [Fact]
    public async Task CancelWithFaultPropagatesException()
    {
        _pipe = new BoundedMemoryStream(1024);
        var fault = new InvalidOperationException("test fault");

        var reader = Task.Run(async () =>
        {
            var buffer = new byte[64];
            return await _pipe.ReadAsync(buffer);
        });

        await Task.Delay(50);
        _pipe.Cancel(fault);

        var ex = await Assert.ThrowsAsync<IOException>(() => reader);
        Assert.Same(fault, ex.InnerException);
    }

    [Fact]
    public async Task ConcurrentReadWriteWithCancellationToken()
    {
        _pipe = new BoundedMemoryStream(64 * 1024);
        var original = new byte[48 * 1024];
        new Random(99).NextBytes(original);

        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(5));

        var writeTask = Task.Run(async () =>
        {
            await _pipe.WriteAsync(original, cts.Token);
            _pipe.CompleteWrite();
        });

        var destination = new byte[original.Length];
        var totalRead = 0;
        while (totalRead < destination.Length)
        {
            var read = await _pipe.ReadAsync(
                destination.AsMemory(totalRead), cts.Token);
            if (read == 0) break;
            totalRead += read;
        }

        await writeTask;
        Assert.Equal(original.Length, totalRead);
        Assert.Equal(original, destination);
    }

    [Fact]
    public async Task WriteAfterCompleteWriteThrows()
    {
        _pipe = new BoundedMemoryStream(1024);
        _pipe.CompleteWrite();

        await Assert.ThrowsAsync<InvalidOperationException>(
            () => _pipe.WriteAsync(new byte[16]));
    }

    [Fact]
    public async Task DisposedPipeRejectsOperations()
    {
        _pipe = new BoundedMemoryStream(1024);
        _pipe.Dispose();

        await Assert.ThrowsAsync<ObjectDisposedException>(
            () => _pipe.WriteAsync(new byte[16]));
        await Assert.ThrowsAsync<ObjectDisposedException>(
            () => _pipe.ReadAsync(new byte[16]));
    }

    [Fact]
    public async Task MultipleSequentialWritesProduceContinuousStream()
    {
        _pipe = new BoundedMemoryStream(64 * 1024);
        var data1 = new byte[1000];
        var data2 = new byte[2000];
        var data3 = new byte[500];
        new Random(7).NextBytes(data1);
        new Random(8).NextBytes(data2);
        new Random(9).NextBytes(data3);

        var writer = Task.Run(async () =>
        {
            await _pipe.WriteAsync(data1);
            await _pipe.WriteAsync(data2);
            await _pipe.WriteAsync(data3);
            _pipe.CompleteWrite();
        });

        var result = new MemoryStream();
        var buffer = new byte[512];
        while (true)
        {
            var read = await _pipe.ReadAsync(buffer);
            if (read == 0) break;
            await result.WriteAsync(buffer.AsMemory(0, read));
        }

        await writer;
        var all = result.ToArray();
        Assert.Equal(data1.Length + data2.Length + data3.Length, all.Length);
        Assert.Equal(data1, all[..data1.Length]);
        Assert.Equal(data2, all[data1.Length..(data1.Length + data2.Length)]);
        Assert.Equal(data3, all[(data1.Length + data2.Length)..]);
    }
}
