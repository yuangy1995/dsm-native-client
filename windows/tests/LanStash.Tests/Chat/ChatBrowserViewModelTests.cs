using LanStash.App.Features.Chat;
using LanStash.Domain;

namespace LanStash.Tests;

public sealed class ChatBrowserViewModelTests
{
    [Fact]
    public void ConversationPresentationHandlesZeroUnreadAndUnicodeInitial()
    {
        var item = new ChatConversationItem(new ChatConversation(
            "a", ChatConversationKind.Direct, "👨‍👩‍👧 Family", [], 1, null, null, 0, false));

        Assert.Equal(string.Empty, item.UnreadText);
        Assert.Equal("👨‍👩‍👧", item.Initial);
    }

    [Fact]
    public void InternalFallbackTitlesBecomeLocalizedAndAutomationNamesExplainUnreadCount()
    {
        var unnamed = new ChatConversationItem(new ChatConversation(
            "channel-1", ChatConversationKind.Direct, "member-1", ["member-1"],
            1, null, null, 0, false));
        var named = new ChatConversationItem(new ChatConversation(
            "channel-2", ChatConversationKind.Group, "Team", [], 3,
            null, null, 4, false));

        Assert.NotEqual("member-1", unnamed.Title);
        Assert.DoesNotContain("channel-1", unnamed.Title, StringComparison.Ordinal);
        Assert.Equal(unnamed.Title, unnamed.AutomationName);
        Assert.Contains("Team", named.AutomationName, StringComparison.Ordinal);
        Assert.Contains("4", named.AutomationName, StringComparison.Ordinal);
    }

    [Fact]
    public void PinnedConversationPresentationUsesIconAndAutomationState()
    {
        var item = new ChatConversationItem(new ChatConversation(
            "channel-1", ChatConversationKind.Direct, "Team", [], 1, null, null, 0, false),
            IsPinned: true);

        Assert.True(item.IsPinned);
        Assert.Contains("Team", item.PinActionAutomationName, StringComparison.Ordinal);
        Assert.Contains(item.Title, item.AutomationName, StringComparison.Ordinal);
        Assert.Contains(item.PinnedStatusText, item.AutomationName, StringComparison.OrdinalIgnoreCase);
        Assert.Equal(Microsoft.UI.Xaml.Visibility.Visible, item.PinnedVisibility);
    }

    [Theory]
    [InlineData("member-1、member-2、member-3")]
    [InlineData("member-1, member-2,member-3")]
    public void MemberIdOnlyGroupTitleBecomesLocalizedUnnamedConversation(string rawTitle)
    {
        var item = new ChatConversationItem(new ChatConversation(
            "channel", ChatConversationKind.Group, rawTitle,
            ["member-1", "member-2", "member-3"], 3, null, null, 0, false));

        Assert.NotEqual(rawTitle, item.Title);
        Assert.DoesNotContain("member-1", item.Title, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("Alice、member-2、member-3")]
    [InlineData("member-1, Bob, member-3")]
    public void MixedDisplayNameGroupTitleRemainsVisible(string title)
    {
        var item = new ChatConversationItem(new ChatConversation(
            "channel", ChatConversationKind.Group, title,
            ["member-1", "member-2", "member-3"], 3, null, null, 0, false));

        Assert.Equal(title, item.Title);
    }

    [Fact]
    public void MissingDisplayNameUsesLocalizedUnknownSenderInsteadOfInternalId()
    {
        var item = new ChatMessageItem(new ChatMessage(
            "m", "c", "internal-user-id", null, null, DateTimeOffset.UnixEpoch,
            "hello", [], ChatEncryptionState.NotEncrypted));

        Assert.NotEqual("internal-user-id", item.Sender);
        Assert.False(string.IsNullOrWhiteSpace(item.Sender));
    }

    [Theory]
    [InlineData(ChatAvailabilityStatus.Unavailable, ChatBrowserContentState.Unavailable)]
    [InlineData(ChatAvailabilityStatus.RequiresValidation, ChatBrowserContentState.RequiresValidation)]
    public async Task UnavailableStatesDoNotIssueChatRequests(
        ChatAvailabilityStatus availability,
        ChatBrowserContentState expected)
    {
        var repository = new FakeChatRepository(Guid.NewGuid(), availability);
        using var model = new ChatBrowserViewModel();

        await model.ActivateAsync(repository);
        await model.RefreshConversationsAsync();

        Assert.Equal(expected, model.ContentState);
        Assert.Equal(0, repository.ConversationRequests);
        Assert.Empty(repository.MessageRequests);
    }

    [Fact]
    public async Task GroupMembersLoadFromMemoryCacheAndRefreshOnDemand()
    {
        var repository = Available(Guid.NewGuid(), canListMembers: true);
        repository.ConversationResults.Enqueue(
            (IReadOnlyList<ChatConversation>)[GroupConversation("group", "Team")]);
        repository.MessageResults.Enqueue(Page("group", [], null, false));
        repository.MemberResults.Enqueue((IReadOnlyList<ChatUser>)[
            new("u-1", "Current", null, false, true),
            new("u-2", "Disabled", null, true, false)]);
        using var model = new ChatBrowserViewModel();
        await model.ActivateAsync(repository);
        await model.SelectConversationAsync(model.Conversations.Single());

        Assert.True(model.CanViewMembers);
        await model.LoadConversationMembersAsync();
        Assert.True(model.HasMembersContent);
        Assert.Equal(new[] { "u-1", "u-2" },
            model.ConversationMembers.Select(member => member.User.Id));
        Assert.True(model.ConversationMembers[0].IsCurrentUser);
        Assert.True(model.ConversationMembers[1].IsDisabled);

        await model.LoadConversationMembersAsync();
        Assert.Single(repository.MemberRequests);

        repository.MemberResults.Enqueue((IReadOnlyList<ChatUser>)[
            new("u-3", "Refreshed", null, false, false)]);
        await model.RefreshConversationMembersAsync();
        Assert.Equal(2, repository.MemberRequests.Count);
        Assert.Equal("u-3", Assert.Single(model.ConversationMembers).User.Id);
    }

    [Fact]
    public async Task MemberEmptyAndErrorStatesDoNotDisturbMessages()
    {
        var repository = Available(Guid.NewGuid(), canListMembers: true);
        repository.ConversationResults.Enqueue(
            (IReadOnlyList<ChatConversation>)[GroupConversation("group", "Team")]);
        repository.MessageResults.Enqueue(Page(
            "group",
            [Message("message", "group", 1)],
            null,
            false));
        repository.MemberResults.Enqueue((IReadOnlyList<ChatUser>)[]);
        repository.MemberResults.Enqueue(new IOException("synthetic"));
        using var model = new ChatBrowserViewModel();
        await model.ActivateAsync(repository);
        await model.SelectConversationAsync(model.Conversations.Single());

        await model.LoadConversationMembersAsync();
        Assert.True(model.IsMembersEmpty);
        Assert.Equal("message", Assert.Single(model.Messages).Id);

        await model.RefreshConversationMembersAsync();
        Assert.True(model.HasMembersError);
        Assert.Equal("message", Assert.Single(model.Messages).Id);
        Assert.False(model.HasMessageError);
    }

    [Fact]
    public async Task DirectConversationAndMissingFeatureIssueNoMemberRequests()
    {
        var directRepository = Available(Guid.NewGuid(), canListMembers: true);
        directRepository.ConversationResults.Enqueue(
            (IReadOnlyList<ChatConversation>)[Conversation("direct", "Direct")]);
        directRepository.MessageResults.Enqueue(Page("direct", [], null, false));
        using (var directModel = new ChatBrowserViewModel())
        {
            await directModel.ActivateAsync(directRepository);
            await directModel.SelectConversationAsync(directModel.Conversations.Single());
            await directModel.LoadConversationMembersAsync();
            Assert.False(directModel.CanViewMembers);
            Assert.Empty(directRepository.MemberRequests);
        }

        var unsupportedRepository = Available(Guid.NewGuid());
        unsupportedRepository.ConversationResults.Enqueue(
            (IReadOnlyList<ChatConversation>)[GroupConversation("group", "Team")]);
        unsupportedRepository.MessageResults.Enqueue(Page("group", [], null, false));
        using var unsupportedModel = new ChatBrowserViewModel();
        await unsupportedModel.ActivateAsync(unsupportedRepository);
        await unsupportedModel.SelectConversationAsync(unsupportedModel.Conversations.Single());
        await unsupportedModel.LoadConversationMembersAsync();
        Assert.False(unsupportedModel.CanViewMembers);
        Assert.Empty(unsupportedRepository.MemberRequests);
    }

    [Fact]
    public async Task SelectionChangeAndCancelRejectLateMemberResults()
    {
        var repository = Available(Guid.NewGuid(), canListMembers: true);
        repository.ConversationResults.Enqueue((IReadOnlyList<ChatConversation>)[
            GroupConversation("a", "Alpha"),
            GroupConversation("b", "Beta")]);
        repository.MessageResults.Enqueue(Page("a", [], null, false));
        repository.MessageResults.Enqueue(Page("b", [], null, false));
        var firstDelayed = new TaskCompletionSource<IReadOnlyList<ChatUser>>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        repository.MemberTasks.Enqueue(firstDelayed.Task);
        using var model = new ChatBrowserViewModel();
        await model.ActivateAsync(repository);
        await model.SelectConversationAsync(model.Conversations.Single(item => item.Id == "a"));

        var firstLoad = model.LoadConversationMembersAsync();
        await WaitUntilAsync(() => repository.MemberRequests.Count == 1);
        await model.SelectConversationAsync(model.Conversations.Single(item => item.Id == "b"));
        firstDelayed.SetResult([new("late-a", "Late A", null, false, false)]);
        await firstLoad;
        Assert.True(model.IsMembersIdle);
        Assert.Empty(model.ConversationMembers);

        var secondDelayed = new TaskCompletionSource<IReadOnlyList<ChatUser>>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        repository.MemberTasks.Enqueue(secondDelayed.Task);
        var secondLoad = model.LoadConversationMembersAsync();
        await WaitUntilAsync(() => repository.MemberRequests.Count == 2);
        model.CancelConversationMembersLoad();
        secondDelayed.SetResult([new("late-b", "Late B", null, false, false)]);
        await secondLoad;
        Assert.True(model.IsMembersIdle);
        Assert.Empty(model.ConversationMembers);
    }

    [Fact]
    public async Task ProfileSwitchRejectsLateMemberResult()
    {
        var firstRepository = Available(Guid.NewGuid(), canListMembers: true);
        firstRepository.ConversationResults.Enqueue(
            (IReadOnlyList<ChatConversation>)[GroupConversation("a", "Alpha")]);
        firstRepository.MessageResults.Enqueue(Page("a", [], null, false));
        var delayed = new TaskCompletionSource<IReadOnlyList<ChatUser>>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        firstRepository.MemberTasks.Enqueue(delayed.Task);
        var secondRepository = Available(Guid.NewGuid(), canListMembers: true);
        secondRepository.ConversationResults.Enqueue(
            (IReadOnlyList<ChatConversation>)[GroupConversation("b", "Beta")]);
        using var model = new ChatBrowserViewModel();
        await model.ActivateAsync(firstRepository);
        await model.SelectConversationAsync(model.Conversations.Single());
        var load = model.LoadConversationMembersAsync();
        await WaitUntilAsync(() => firstRepository.MemberRequests.Count == 1);

        await model.ActivateAsync(secondRepository);
        delayed.SetResult([new("late", "Late", null, false, false)]);
        await load;

        Assert.Equal(secondRepository.ProfileId, model.ActiveProfileId);
        Assert.True(model.IsMembersIdle);
        Assert.Empty(model.ConversationMembers);
    }

    [Fact]
    public async Task GroupAnnouncementsCoverContentCacheRefreshAndFailureWithoutAffectingMessages()
    {
        var repository = Available(Guid.NewGuid(), canListAnnouncements: true);
        repository.ConversationResults.Enqueue(
            (IReadOnlyList<ChatConversation>)[GroupConversation("group", "Team")]);
        repository.MessageResults.Enqueue(Page("group", [Message("message", "group", 1)], null, false));
        repository.AnnouncementResults.Enqueue((IReadOnlyList<ChatPinnedMessage>)[
            Announcement("pin-1", "group", 2)]);
        repository.AnnouncementResults.Enqueue((IReadOnlyList<ChatPinnedMessage>)[]);
        repository.AnnouncementResults.Enqueue(new InvalidOperationException("synthetic"));
        using var model = new ChatBrowserViewModel();
        await model.ActivateAsync(repository);
        await model.SelectConversationAsync(model.Conversations.Single());

        Assert.True(model.CanViewAnnouncements);
        await model.LoadConversationAnnouncementsAsync();
        Assert.True(model.HasAnnouncementsContent);
        Assert.Equal("pin-1", Assert.Single(model.ConversationAnnouncements).Message.Id);
        await model.LoadConversationAnnouncementsAsync();
        Assert.Single(repository.AnnouncementRequests);

        await model.RefreshConversationAnnouncementsAsync();
        Assert.True(model.IsAnnouncementsEmpty);
        Assert.Empty(model.ConversationAnnouncements);

        await model.RefreshConversationAnnouncementsAsync();
        Assert.True(model.HasAnnouncementsError);
        Assert.Empty(model.ConversationAnnouncements);
        Assert.Equal("message", Assert.Single(model.Messages).Id);
        Assert.False(model.HasMessageError);
    }

    [Fact]
    public async Task AnnouncementSelectionChangeAndCancelRejectLateResults()
    {
        var repository = Available(Guid.NewGuid(), canListAnnouncements: true);
        repository.ConversationResults.Enqueue((IReadOnlyList<ChatConversation>)[
            GroupConversation("a", "Alpha"),
            GroupConversation("b", "Beta")]);
        repository.MessageResults.Enqueue(Page("a", [], null, false));
        repository.MessageResults.Enqueue(Page("b", [], null, false));
        var firstDelayed = new TaskCompletionSource<IReadOnlyList<ChatPinnedMessage>>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        repository.AnnouncementTasks.Enqueue(firstDelayed.Task);
        using var model = new ChatBrowserViewModel();
        await model.ActivateAsync(repository);
        await model.SelectConversationAsync(model.Conversations.Single(item => item.Id == "a"));

        var firstLoad = model.LoadConversationAnnouncementsAsync();
        await WaitUntilAsync(() => repository.AnnouncementRequests.Count == 1);
        await model.SelectConversationAsync(model.Conversations.Single(item => item.Id == "b"));
        firstDelayed.SetResult([Announcement("late-a", "a", 2)]);
        await firstLoad;
        Assert.True(model.IsAnnouncementsIdle);
        Assert.Empty(model.ConversationAnnouncements);

        var secondDelayed = new TaskCompletionSource<IReadOnlyList<ChatPinnedMessage>>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        repository.AnnouncementTasks.Enqueue(secondDelayed.Task);
        var secondLoad = model.LoadConversationAnnouncementsAsync();
        await WaitUntilAsync(() => repository.AnnouncementRequests.Count == 2);
        model.CancelConversationAnnouncementsLoad();
        secondDelayed.SetResult([Announcement("late-b", "b", 3)]);
        await secondLoad;
        Assert.True(model.IsAnnouncementsIdle);
        Assert.Empty(model.ConversationAnnouncements);
    }

    [Fact]
    public async Task DirectEncryptedAndMissingFeatureIssueNoAnnouncementRequests()
    {
        foreach (var conversation in new[]
        {
            Conversation("direct", "Direct"),
            new ChatConversation("encrypted", ChatConversationKind.Group, "Encrypted", [], 3,
                null, DateTimeOffset.UnixEpoch, 0, true),
        })
        {
            var repository = Available(Guid.NewGuid(), canListAnnouncements: true);
            repository.ConversationResults.Enqueue((IReadOnlyList<ChatConversation>)[conversation]);
            if (!conversation.IsEncrypted)
            {
                repository.MessageResults.Enqueue(Page(conversation.Id, [], null, false));
            }
            using var model = new ChatBrowserViewModel();
            await model.ActivateAsync(repository);
            await model.SelectConversationAsync(model.Conversations.Single());
            await model.LoadConversationAnnouncementsAsync();
            Assert.False(model.CanViewAnnouncements);
            Assert.Empty(repository.AnnouncementRequests);
        }

        var unsupported = Available(Guid.NewGuid());
        unsupported.ConversationResults.Enqueue(
            (IReadOnlyList<ChatConversation>)[GroupConversation("group", "Team")]);
        unsupported.MessageResults.Enqueue(Page("group", [], null, false));
        using var unsupportedModel = new ChatBrowserViewModel();
        await unsupportedModel.ActivateAsync(unsupported);
        await unsupportedModel.SelectConversationAsync(unsupportedModel.Conversations.Single());
        await unsupportedModel.LoadConversationAnnouncementsAsync();
        Assert.False(unsupportedModel.CanViewAnnouncements);
        Assert.Empty(unsupported.AnnouncementRequests);
    }

    [Fact]
    public async Task FilteredRefreshClearingSelectionCancelsBlockedMessageAndRejectsLateResult()
    {
        var repository = Available(Guid.NewGuid());
        repository.ConversationResults.Enqueue(
            (IReadOnlyList<ChatConversation>)[Conversation("a", "Alpha")]);
        repository.ConversationResults.Enqueue(
            (IReadOnlyList<ChatConversation>)[Conversation("a", "Alpha")]);
        var delayed = new TaskCompletionSource<ChatMessagePage>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        repository.MessageTasks.Enqueue(delayed.Task);
        using var model = new ChatBrowserViewModel();
        await model.ActivateAsync(repository);

        var blocked = model.SelectConversationAsync(model.Conversations.Single());
        await WaitUntilAsync(() => model.IsLoadingMessages);
        model.SearchQuery = "missing";
        await model.RefreshConversationsAsync();

        Assert.Null(model.SelectedConversation);
        Assert.False(model.IsLoadingMessages);
        Assert.False(model.IsLoadingEarlier);
        Assert.Empty(model.Messages);
        delayed.SetResult(Page("a", [Message("late", "a", 1)], null, false));
        await blocked;
        Assert.Empty(model.Messages);
        Assert.False(model.IsLoadingMessages);
        Assert.False(model.IsLoadingEarlier);
    }

    [Fact]
    public async Task ConversationsHaveFiveStatesAndFilteringIsLocal()
    {
        var profile = Guid.NewGuid();
        var repository = Available(profile);
        repository.ConversationResults.Enqueue(
            (IReadOnlyList<ChatConversation>)[Conversation("a", "Alpha", "first")]);
        using var model = new ChatBrowserViewModel();

        await model.ActivateAsync(repository);
        Assert.Equal(ChatBrowserContentState.Content, model.ContentState);
        model.SearchQuery = "missing";
        Assert.Equal(ChatBrowserContentState.FilteredEmpty, model.ContentState);
        model.SearchQuery = "first";
        Assert.Equal("a", Assert.Single(model.Conversations).Id);
        Assert.Equal(1, repository.ConversationRequests);

        model.SearchQuery = string.Empty;
        repository.ConversationResults.Enqueue((IReadOnlyList<ChatConversation>)[]);
        await model.RefreshConversationsAsync();
        Assert.Equal(ChatBrowserContentState.Empty, model.ContentState);

        repository.ConversationResults.Enqueue(new IOException("synthetic"));
        await model.RefreshConversationsAsync();
        Assert.Equal(ChatBrowserContentState.Error, model.ContentState);
    }

    [Fact]
    public async Task LocalPinsSortFirstPersistByProfileAndStayLocal()
    {
        var profile = Guid.NewGuid();
        var pins = new MemoryPinStore();
        var repository = Available(profile);
        repository.ConversationResults.Enqueue(
            (IReadOnlyList<ChatConversation>)[
                Conversation("a", "Alpha", "match"),
                Conversation("b", "Beta", "match"),
                Conversation("c", "Charlie", "match")]);
        using var model = new ChatBrowserViewModel(
            ChatBrowserViewModel.DefaultPageSize,
            pins);

        await model.ActivateAsync(repository);
        Assert.Equal(["c", "b", "a"], model.Conversations.Select(value => value.Id));

        await model.ToggleConversationPinAsync(model.Conversations.Single(value => value.Id == "b"));
        Assert.Equal(["b", "c", "a"], model.Conversations.Select(value => value.Id));
        Assert.Equal(["b"], pins.Saved[profile]);
        Assert.Equal(1, repository.ConversationRequests);
        Assert.Empty(repository.MessageRequests);

        await model.ToggleConversationPinAsync(model.Conversations.Single(value => value.Id == "c"));
        Assert.Equal(["c", "b", "a"], model.Conversations.Select(value => value.Id));
        model.SearchQuery = "match";
        Assert.Equal(["c", "b", "a"], model.Conversations.Select(value => value.Id));

        await model.ToggleConversationPinAsync(model.Conversations.Single(value => value.Id == "b"));
        Assert.Equal(["c", "b", "a"], model.Conversations.Select(value => value.Id));
        Assert.Equal(["c"], pins.Saved[profile]);
        Assert.Equal(1, repository.ConversationRequests);
    }

    [Fact]
    public async Task StoredPinsAreProfileScopedAndSurviveModelRecreation()
    {
        var profileA = Guid.NewGuid();
        var profileB = Guid.NewGuid();
        var pins = new MemoryPinStore();
        pins.Saved[profileA] = ["a"];
        pins.Saved[profileB] = ["b"];
        var firstA = Available(profileA);
        firstA.ConversationResults.Enqueue(
            (IReadOnlyList<ChatConversation>)[Conversation("a", "Alpha"), Conversation("b", "Beta")]);
        var firstB = Available(profileB);
        firstB.ConversationResults.Enqueue(
            (IReadOnlyList<ChatConversation>)[Conversation("a", "Alpha"), Conversation("b", "Beta")]);
        using var first = new ChatBrowserViewModel(ChatBrowserViewModel.DefaultPageSize, pins);

        await first.ActivateAsync(firstA);
        Assert.Equal("a", first.Conversations[0].Id);
        await first.ActivateAsync(firstB);
        Assert.Equal("b", first.Conversations[0].Id);

        var secondA = Available(profileA);
        secondA.ConversationResults.Enqueue(
            (IReadOnlyList<ChatConversation>)[Conversation("a", "Alpha"), Conversation("b", "Beta")]);
        using var second = new ChatBrowserViewModel(ChatBrowserViewModel.DefaultPageSize, pins);
        await second.ActivateAsync(secondA);

        Assert.Equal("a", second.Conversations[0].Id);
        Assert.Equal([profileA, profileB, profileA], pins.LoadedProfiles);
    }

    [Fact]
    public async Task PinSaveFailureKeepsLocalOrderingButReportsRecoverableError()
    {
        var repository = Available(Guid.NewGuid());
        repository.ConversationResults.Enqueue(
            (IReadOnlyList<ChatConversation>)[Conversation("a", "Alpha"), Conversation("b", "Beta")]);
        using var model = new ChatBrowserViewModel(
            ChatBrowserViewModel.DefaultPageSize,
            new FailingSavePinStore());

        await model.ActivateAsync(repository);
        await model.ToggleConversationPinAsync(model.Conversations.Single(value => value.Id == "a"));

        Assert.True(model.HasPinStorageError);
        Assert.Equal("a", model.Conversations[0].Id);
        Assert.Equal(1, repository.ConversationRequests);
        Assert.Empty(repository.MessageRequests);
    }

    [Fact]
    public async Task ProfileRestoresItsSearchSelectionAndMessagesWithoutNewRequests()
    {
        var profileA = Guid.NewGuid();
        var a = Available(profileA);
        a.ConversationResults.Enqueue(
            (IReadOnlyList<ChatConversation>)[Conversation("a", "Alpha", "match")]);
        a.MessageResults.Enqueue(Page("a", [Message("m1", "a", 1)], null, false));
        var b = Available(Guid.NewGuid());
        b.ConversationResults.Enqueue(
            (IReadOnlyList<ChatConversation>)[Conversation("b", "Beta")]);
        using var model = new ChatBrowserViewModel();

        await model.ActivateAsync(a);
        model.SearchQuery = "match";
        await model.SelectConversationAsync(model.Conversations.Single());
        await model.ActivateAsync(b);
        await model.ActivateAsync(a);

        Assert.Equal("match", model.SearchQuery);
        Assert.Equal("a", model.SelectedConversation?.Id);
        Assert.Equal("m1", Assert.Single(model.Messages).Id);
        Assert.Equal(1, a.ConversationRequests);
        Assert.Single(a.MessageRequests);
    }

    [Fact]
    public async Task EncryptedConversationNeverRequestsOrRevealsMessages()
    {
        var repository = Available(Guid.NewGuid());
        repository.ConversationResults.Enqueue(
            (IReadOnlyList<ChatConversation>)[Conversation("locked", "Locked", encrypted: true)]);
        using var model = new ChatBrowserViewModel();
        await model.ActivateAsync(repository);

        await model.SelectConversationAsync(model.Conversations.Single());

        Assert.True(model.IsEncryptedSelection);
        Assert.Empty(model.Messages);
        Assert.Empty(repository.MessageRequests);
    }

    [Fact]
    public async Task RawCursorLoadsEarlierAndDeduplicatesInChronologicalOrder()
    {
        var repository = Available(Guid.NewGuid());
        repository.ConversationResults.Enqueue(
            (IReadOnlyList<ChatConversation>)[Conversation("a", "Alpha")]);
        repository.MessageResults.Enqueue(Page("a", [Message("m2", "a", 2)], "50", true));
        repository.MessageResults.Enqueue(Page("a", [Message("m1", "a", 1), Message("m2", "a", 2)], null, false, 50));
        using var model = new ChatBrowserViewModel();
        await model.ActivateAsync(repository);
        await model.SelectConversationAsync(model.Conversations.Single());

        await model.LoadEarlierAsync();

        Assert.Equal(["m1", "m2"], model.Messages.Select(value => value.Id));
        Assert.Equal([null, "50"], repository.MessageRequests.Select(value => value.Cursor));
        Assert.False(model.CanLoadEarlier);
    }

    [Fact]
    public async Task MessageFailuresKeepVisibleContentAndCanRetrySameCursor()
    {
        var repository = Available(Guid.NewGuid());
        repository.ConversationResults.Enqueue(
            (IReadOnlyList<ChatConversation>)[Conversation("a", "Alpha")]);
        repository.MessageResults.Enqueue(Page("a", [Message("m2", "a", 2)], "10", true));
        repository.MessageResults.Enqueue(new IOException("synthetic"));
        repository.MessageResults.Enqueue(Page("a", [Message("m1", "a", 1)], null, false, 10));
        using var model = new ChatBrowserViewModel();
        await model.ActivateAsync(repository);
        await model.SelectConversationAsync(model.Conversations.Single());

        await model.LoadEarlierAsync();
        Assert.True(model.HasLoadEarlierError);
        Assert.Equal("m2", Assert.Single(model.Messages).Id);
        await model.LoadEarlierAsync();

        Assert.False(model.HasLoadEarlierError);
        Assert.Equal(["10", "10"], repository.MessageRequests.Skip(1).Select(value => value.Cursor));
        Assert.Equal(["m1", "m2"], model.Messages.Select(value => value.Id));
    }

    [Fact]
    public async Task ConversationBecomingEncryptedPurgesItsCachedMessages()
    {
        var repository = Available(Guid.NewGuid());
        repository.ConversationResults.Enqueue(
            (IReadOnlyList<ChatConversation>)[Conversation("a", "Alpha")]);
        repository.ConversationResults.Enqueue(
            (IReadOnlyList<ChatConversation>)[Conversation("a", "Alpha", encrypted: true)]);
        repository.ConversationResults.Enqueue(
            (IReadOnlyList<ChatConversation>)[Conversation("a", "Alpha")]);
        repository.MessageResults.Enqueue(Page("a", [Message("secret", "a", 1)], null, false));
        repository.MessageResults.Enqueue(Page("a", [Message("fresh", "a", 2)], null, false));
        using var model = new ChatBrowserViewModel();
        await model.ActivateAsync(repository);
        await model.SelectConversationAsync(model.Conversations.Single());
        Assert.Equal("secret", Assert.Single(model.Messages).Id);

        await model.RefreshConversationsAsync();
        Assert.True(model.IsEncryptedSelection);
        Assert.Empty(model.Messages);
        await model.RefreshConversationsAsync();
        await model.SelectConversationAsync(model.Conversations.Single());

        Assert.Equal("fresh", Assert.Single(model.Messages).Id);
        Assert.Equal(2, repository.MessageRequests.Count);
    }

    [Fact]
    public async Task StaleMessageResponseCannotOverwriteNewConversation()
    {
        var repository = Available(Guid.NewGuid());
        repository.ConversationResults.Enqueue(
            (IReadOnlyList<ChatConversation>)[
                Conversation("a", "Alpha"), Conversation("b", "Beta")]);
        var delayed = new TaskCompletionSource<ChatMessagePage>(TaskCreationOptions.RunContinuationsAsynchronously);
        repository.MessageTasks.Enqueue(delayed.Task);
        repository.MessageResults.Enqueue(Page("b", [Message("b1", "b", 2)], null, false));
        using var model = new ChatBrowserViewModel();
        await model.ActivateAsync(repository);

        var first = model.SelectConversationAsync(model.Conversations.Single(value => value.Id == "a"));
        await WaitUntilAsync(() => repository.MessageRequests.Count == 1);
        await model.SelectConversationAsync(model.Conversations.Single(value => value.Id == "b"));
        delayed.SetResult(Page("a", [Message("a1", "a", 1)], null, false));
        await first;

        Assert.Equal("b", model.SelectedConversation?.Id);
        Assert.Equal("b1", Assert.Single(model.Messages).Id);
    }

    private static FakeChatRepository Available(
        Guid profileId,
        bool canListMembers = false,
        bool canListAnnouncements = false) =>
        new(profileId, ChatAvailabilityStatus.Available, canListMembers, canListAnnouncements);

    private static ChatConversation Conversation(
        string id,
        string title,
        string? summary = null,
        bool encrypted = false) =>
        new(id, ChatConversationKind.Direct, title, [], 2, summary,
            DateTimeOffset.UnixEpoch.AddMinutes(id[0]), 0, encrypted);

    private static ChatConversation GroupConversation(string id, string title) =>
        new(id, ChatConversationKind.Group, title, [], 3, null,
            DateTimeOffset.UnixEpoch.AddMinutes(id[0]), 0, false);

    private static ChatMessage Message(string id, string conversationId, int minute) =>
        new(id, conversationId, "user", "User", false,
            DateTimeOffset.UnixEpoch.AddMinutes(minute), id, [], ChatEncryptionState.NotEncrypted);

    private static ChatPinnedMessage Announcement(string id, string conversationId, int minute) =>
        new(id, conversationId, "user", "User",
            DateTimeOffset.UnixEpoch.AddMinutes(minute - 1),
            DateTimeOffset.UnixEpoch.AddMinutes(minute),
            id);

    private static ChatMessagePage Page(
        string conversationId,
        IReadOnlyList<ChatMessage> messages,
        string? cursor,
        bool hasMore,
        int offset = 0) =>
        new(messages, cursor, hasMore, offset, messages.Count, null);

    private static async Task WaitUntilAsync(Func<bool> predicate)
    {
        for (var attempt = 0; attempt < 100 && !predicate(); attempt++)
        {
            await Task.Yield();
        }
        Assert.True(predicate());
    }

    private sealed class FakeChatRepository(
        Guid profileId,
        ChatAvailabilityStatus status,
        bool canListMembers = false,
        bool canListAnnouncements = false) : IChatRepository
    {
        public Guid ProfileId { get; } = profileId;
        public ChatAvailability Availability { get; } = new(status,
            status == ChatAvailabilityStatus.Available
                ? new HashSet<ChatReadFeature>(new[]
                    {
                        ChatReadFeature.Conversations,
                        ChatReadFeature.Messages,
                    }
                    .Concat(canListMembers ? [ChatReadFeature.Members] : [])
                    .Concat(canListAnnouncements ? [ChatReadFeature.PinnedMessages] : []))
                : new HashSet<ChatReadFeature>());
        public Queue<object> ConversationResults { get; } = [];
        public Queue<object> MemberResults { get; } = [];
        public Queue<object> AnnouncementResults { get; } = [];
        public Queue<object> MessageResults { get; } = [];
        public Queue<Task<IReadOnlyList<ChatUser>>> MemberTasks { get; } = [];
        public Queue<Task<IReadOnlyList<ChatPinnedMessage>>> AnnouncementTasks { get; } = [];
        public Queue<Task<ChatMessagePage>> MessageTasks { get; } = [];
        public int ConversationRequests { get; private set; }
        public List<string> MemberRequests { get; } = [];
        public List<string> AnnouncementRequests { get; } = [];
        public List<(string ConversationId, string? Cursor)> MessageRequests { get; } = [];

        public Task<IReadOnlyList<ChatUser>> ListUsersAsync(CancellationToken cancellationToken = default) =>
            Task.FromResult<IReadOnlyList<ChatUser>>([]);

        public Task<IReadOnlyList<ChatUser>> ListConversationMembersAsync(
            string conversationId,
            CancellationToken cancellationToken = default)
        {
            MemberRequests.Add(conversationId);
            if (MemberTasks.Count > 0)
            {
                return MemberTasks.Dequeue();
            }
            var result = MemberResults.Dequeue();
            return result is Exception error
                ? Task.FromException<IReadOnlyList<ChatUser>>(error)
                : Task.FromResult((IReadOnlyList<ChatUser>)result);
        }

        public Task<IReadOnlyList<ChatPinnedMessage>> ListPinnedMessagesAsync(
            string conversationId,
            CancellationToken cancellationToken = default)
        {
            AnnouncementRequests.Add(conversationId);
            if (AnnouncementTasks.Count > 0)
            {
                return AnnouncementTasks.Dequeue();
            }
            var result = AnnouncementResults.Dequeue();
            return result is Exception error
                ? Task.FromException<IReadOnlyList<ChatPinnedMessage>>(error)
                : Task.FromResult((IReadOnlyList<ChatPinnedMessage>)result);
        }

        public Task<IReadOnlyList<ChatConversation>> ListConversationsAsync(CancellationToken cancellationToken = default)
        {
            ConversationRequests++;
            var result = ConversationResults.Dequeue();
            return result is Exception error
                ? Task.FromException<IReadOnlyList<ChatConversation>>(error)
                : Task.FromResult((IReadOnlyList<ChatConversation>)result);
        }

        public Task<ChatMessagePage> ListMessagesAsync(
            string conversationId,
            string? beforeCursor,
            int limit,
            CancellationToken cancellationToken = default)
        {
            MessageRequests.Add((conversationId, beforeCursor));
            if (MessageTasks.Count > 0)
            {
                return MessageTasks.Dequeue();
            }
            var result = MessageResults.Dequeue();
            return result is Exception error
                ? Task.FromException<ChatMessagePage>(error)
                : Task.FromResult((ChatMessagePage)result);
        }

        public Task<ChatTextSendOutcome> SendTextAsync(
            ChatTextSendRequest request,
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();
    }

    private sealed class MemoryPinStore : IChatConversationPinStore
    {
        public Dictionary<Guid, IReadOnlyList<string>> Saved { get; } = [];
        public List<Guid> LoadedProfiles { get; } = [];

        public Task<IReadOnlyList<string>> LoadAsync(
            Guid profileId,
            CancellationToken cancellationToken = default)
        {
            LoadedProfiles.Add(profileId);
            return Task.FromResult(Saved.GetValueOrDefault(profileId) ?? (IReadOnlyList<string>)[]);
        }

        public Task<bool> SaveAsync(
            Guid profileId,
            IReadOnlyList<string> conversationIds,
            CancellationToken cancellationToken = default)
        {
            Saved[profileId] = conversationIds.ToArray();
            return Task.FromResult(true);
        }

        public Task<bool> RemoveAsync(
            Guid profileId,
            CancellationToken cancellationToken = default)
        {
            Saved.Remove(profileId);
            return Task.FromResult(true);
        }
    }

    private sealed class FailingSavePinStore : IChatConversationPinStore
    {
        public Task<IReadOnlyList<string>> LoadAsync(
            Guid profileId,
            CancellationToken cancellationToken = default) =>
            Task.FromResult<IReadOnlyList<string>>([]);

        public Task<bool> SaveAsync(
            Guid profileId,
            IReadOnlyList<string> conversationIds,
            CancellationToken cancellationToken = default) =>
            Task.FromResult(false);

        public Task<bool> RemoveAsync(
            Guid profileId,
            CancellationToken cancellationToken = default) =>
            Task.FromResult(false);
    }
}
