using LanStash.App.Features.Chat;

namespace LanStash.Tests;

public sealed class ChatConversationPinStoreTests
{
    [Fact]
    public async Task PinsAreProfileScopedNormalizedAndPersisted()
    {
        var directory = Directory.CreateTempSubdirectory("lanstash-chat-pins-");
        try
        {
            var store = new FileChatConversationPinStore(directory.FullName);
            var profileA = Guid.NewGuid();
            var profileB = Guid.NewGuid();

            Assert.Empty(await store.LoadAsync(profileA));
            Assert.True(await store.SaveAsync(profileA, [" b ", "a", "b", "", "c"]));

            Assert.Equal(["b", "a", "c"], await store.LoadAsync(profileA));
            Assert.Empty(await store.LoadAsync(profileB));

            Assert.True(await store.RemoveAsync(profileA));
            Assert.Empty(await store.LoadAsync(profileA));
        }
        finally
        {
            directory.Delete(recursive: true);
        }
    }

    [Fact]
    public async Task CorruptLocalPinsFallBackToEmptyState()
    {
        var directory = Directory.CreateTempSubdirectory("lanstash-chat-pins-");
        try
        {
            var store = new FileChatConversationPinStore(directory.FullName);
            var profile = Guid.NewGuid();
            File.WriteAllText(Path.Combine(directory.FullName, $"{profile:N}.json"), "{not-json");

            Assert.Empty(await store.LoadAsync(profile));
        }
        finally
        {
            directory.Delete(recursive: true);
        }
    }

    [Fact]
    public async Task CancelledSaveDoesNotPublishHalfState()
    {
        var directory = Directory.CreateTempSubdirectory("lanstash-chat-pins-");
        try
        {
            var store = new FileChatConversationPinStore(directory.FullName);
            var profile = Guid.NewGuid();
            using var cancellation = new CancellationTokenSource();
            cancellation.Cancel();

            await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
                store.SaveAsync(profile, ["a"], cancellation.Token));
            Assert.Empty(await store.LoadAsync(profile));
        }
        finally
        {
            directory.Delete(recursive: true);
        }
    }
}
