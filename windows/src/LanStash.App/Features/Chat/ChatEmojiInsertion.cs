namespace LanStash.App.Features.Chat;

internal static class ChatEmojiInsertion
{
    public static (string Text, int Caret) Apply(
        string? text,
        int selectionStart,
        int selectionLength,
        string emoji)
    {
        ArgumentException.ThrowIfNullOrEmpty(emoji);
        var current = text ?? string.Empty;
        var start = Math.Clamp(selectionStart, 0, current.Length);
        var length = Math.Clamp(selectionLength, 0, current.Length - start);
        var updated = current.Remove(start, length).Insert(start, emoji);
        return (updated, start + emoji.Length);
    }
}
