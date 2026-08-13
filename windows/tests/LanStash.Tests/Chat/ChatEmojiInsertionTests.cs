using LanStash.App.Features.Chat;

namespace LanStash.Tests;

public sealed class ChatEmojiInsertionTests
{
    [Theory]
    [InlineData(null, 0, 0, "😀", "😀", 2)]
    [InlineData("ab", 1, 0, "😀", "a😀b", 3)]
    [InlineData("abcd", 1, 2, "👍", "a👍d", 3)]
    [InlineData("ab", -10, 0, "✅", "✅ab", 1)]
    [InlineData("ab", 20, 20, "✨", "ab✨", 3)]
    public void AppliesEmojiAtClampedSelection(
        string? text,
        int start,
        int length,
        string emoji,
        string expected,
        int expectedCaret)
    {
        var result = ChatEmojiInsertion.Apply(text, start, length, emoji);

        Assert.Equal(expected, result.Text);
        Assert.Equal(expectedCaret, result.Caret);
    }
}
