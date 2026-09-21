using System.Runtime.CompilerServices;

namespace LanStash.Domain;

/// <summary>实时通道只通知状态变化，消息内容必须通过既有 API 回读。</summary>
public enum ChatRealtimeEvent { Connected, Disconnected, ContentChanged }

internal static class ChatRealtimeStreams
{
    public static async IAsyncEnumerable<ChatRealtimeEvent> Empty([EnumeratorCancellation] CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        await Task.CompletedTask;
        yield break;
    }
}
