namespace LanStash.App.Features.Settings;

// 将同一 UI 消息循环中的多次属性变更合并为一次呈现；停止后不得排入新的工作。
public sealed class PresentationInvalidation
{
    private int _queued;
    private int _stopped;
    public bool TryRequest() => Volatile.Read(ref _stopped) == 0 &&
        Interlocked.Exchange(ref _queued, 1) == 0;
    public bool Consume()
    {
        Interlocked.Exchange(ref _queued, 0);
        return Volatile.Read(ref _stopped) == 0;
    }
    public void Stop() => Interlocked.Exchange(ref _stopped, 1);
}
