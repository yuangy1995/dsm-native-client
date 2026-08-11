using System.Collections.ObjectModel;
using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.Chat;

public sealed class ChatBrowserViewModel : ObservableObject, IDisposable
{
    public const int DefaultPageSize = 50;

    private readonly int _pageSize;
    private readonly IChatConversationPinStore _pinStore;
    private readonly Dictionary<Guid, ProfileCache> _profiles = [];
    private IChatRepository? _repository;
    private CancellationTokenSource? _conversationCancellation;
    private CancellationTokenSource? _messageCancellation;
    private long _conversationGeneration;
    private long _messageGeneration;
    private Guid? _activeProfileId;
    private ChatBrowserContentState _contentState = ChatBrowserContentState.Loading;
    private ChatConversationItem? _selectedConversation;
    private string _searchQuery = string.Empty;
    private bool _isLoadingConversations;
    private bool _isLoadingMessages;
    private bool _isLoadingEarlier;
    private bool _hasConversationError;
    private bool _hasMessageError;
    private bool _hasLoadEarlierError;
    private bool _hasPinStorageError;
    private bool _disposed;

    public ChatBrowserViewModel(int pageSize = DefaultPageSize)
        : this(pageSize, new FileChatConversationPinStore())
    {
    }

    internal ChatBrowserViewModel(
        int pageSize,
        IChatConversationPinStore pinStore)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(pageSize, 1);
        ArgumentNullException.ThrowIfNull(pinStore);
        _pageSize = pageSize;
        _pinStore = pinStore;
    }

    public ObservableCollection<ChatConversationItem> Conversations { get; } = [];
    public ObservableCollection<ChatMessageItem> Messages { get; } = [];

    public Guid? ActiveProfileId
    {
        get => _activeProfileId;
        private set => SetProperty(ref _activeProfileId, value);
    }

    public ChatBrowserContentState ContentState
    {
        get => _contentState;
        private set
        {
            if (SetProperty(ref _contentState, value))
            {
                RaiseStateProperties();
            }
        }
    }

    public ChatConversationItem? SelectedConversation
    {
        get => _selectedConversation;
        private set
        {
            if (SetProperty(ref _selectedConversation, value))
            {
                RaisePropertyChanged(nameof(HasSelection));
                RaisePropertyChanged(nameof(IsEncryptedSelection));
                RaisePropertyChanged(nameof(CanLoadEarlier));
            }
        }
    }

    public string SearchQuery
    {
        get => _searchQuery;
        set
        {
            var normalized = value ?? string.Empty;
            if (SetProperty(ref _searchQuery, normalized))
            {
                if (CurrentProfile is { } profile)
                {
                    profile.SearchQuery = normalized;
                }
                ApplyConversationFilter();
            }
        }
    }

    public bool IsLoadingConversations
    {
        get => _isLoadingConversations;
        private set => SetProperty(ref _isLoadingConversations, value);
    }

    public bool IsLoadingMessages
    {
        get => _isLoadingMessages;
        private set => SetProperty(ref _isLoadingMessages, value);
    }

    public bool IsLoadingEarlier
    {
        get => _isLoadingEarlier;
        private set
        {
            if (SetProperty(ref _isLoadingEarlier, value))
            {
                RaisePropertyChanged(nameof(CanLoadEarlier));
            }
        }
    }

    public bool HasConversationError
    {
        get => _hasConversationError;
        private set => SetProperty(ref _hasConversationError, value);
    }

    public bool HasMessageError
    {
        get => _hasMessageError;
        private set => SetProperty(ref _hasMessageError, value);
    }

    public bool HasLoadEarlierError
    {
        get => _hasLoadEarlierError;
        private set => SetProperty(ref _hasLoadEarlierError, value);
    }

    public bool HasPinStorageError
    {
        get => _hasPinStorageError;
        private set => SetProperty(ref _hasPinStorageError, value);
    }

    public bool HasSelection => SelectedConversation is not null;
    public bool IsEncryptedSelection => SelectedConversation?.IsEncrypted == true;
    public bool HasContent => ContentState == ChatBrowserContentState.Content;
    public bool IsEmpty => ContentState == ChatBrowserContentState.Empty;
    public bool IsFilteredEmpty => ContentState == ChatBrowserContentState.FilteredEmpty;
    public bool HasError => ContentState == ChatBrowserContentState.Error;
    public bool IsUnavailable => ContentState == ChatBrowserContentState.Unavailable;
    public bool RequiresValidation => ContentState == ChatBrowserContentState.RequiresValidation;
    public bool CanLoadEarlier => SelectedConversation is { IsEncrypted: false } &&
        !IsLoadingMessages && !IsLoadingEarlier && (CurrentConversationCache?.HasMoreBefore ?? false);

    private ProfileCache? CurrentProfile => ActiveProfileId is Guid id &&
        _profiles.TryGetValue(id, out var cache) ? cache : null;

    private ConversationCache? CurrentConversationCache =>
        SelectedConversation is { } selected && CurrentProfile is { } profile &&
        profile.Messages.TryGetValue(selected.Id, out var cache) ? cache : null;

    public async Task ActivateAsync(IChatRepository repository)
    {
        ThrowIfDisposed();
        ArgumentNullException.ThrowIfNull(repository);
        SaveCurrentProfileState();
        CancelAllRequests();
        _repository = repository;
        ActiveProfileId = repository.ProfileId;

        if (repository.Availability.Status != ChatAvailabilityStatus.Available)
        {
            Conversations.Clear();
            Messages.Clear();
            SelectedConversation = null;
            ContentState = repository.Availability.Status == ChatAvailabilityStatus.RequiresValidation
                ? ChatBrowserContentState.RequiresValidation
                : ChatBrowserContentState.Unavailable;
            return;
        }

        var profile = GetOrCreateProfile(repository.ProfileId);
        RestoreSearchQuery(profile);
        await EnsurePinsLoadedAsync(repository.ProfileId, profile);

        if (profile.Loaded)
        {
            ApplyPinState(profile);
            RestoreProfile(profile);
            return;
        }

        await LoadConversationsAsync(profile, preserveContentOnFailure: false);
    }

    public void Deactivate()
    {
        ThrowIfDisposed();
        SaveCurrentProfileState();
        CancelAllRequests();
        _repository = null;
        ActiveProfileId = null;
        Conversations.Clear();
        Messages.Clear();
        SelectedConversation = null;
        ContentState = ChatBrowserContentState.Loading;
        ResetErrors();
    }

    public Task RefreshConversationsAsync()
    {
        ThrowIfDisposed();
        return _repository is { Availability.Status: ChatAvailabilityStatus.Available } &&
            CurrentProfile is { } profile
                ? LoadConversationsAsync(profile, preserveContentOnFailure: true)
                : Task.CompletedTask;
    }

    public async Task SelectConversationAsync(ChatConversationItem? item)
    {
        ThrowIfDisposed();
        if (item is null || !Conversations.Any(value => value.Id == item.Id))
        {
            return;
        }

        CancelMessageRequest();
        SelectedConversation = item;
        RequireProfile().SelectedConversationId = item.Id;
        Messages.Clear();
        HasMessageError = false;
        HasLoadEarlierError = false;
        if (item.IsEncrypted)
        {
            RaisePropertyChanged(nameof(CanLoadEarlier));
            return;
        }

        if (CurrentConversationCache is { Loaded: true } cached)
        {
            ReplaceMessages(cached.Messages);
            RaisePropertyChanged(nameof(CanLoadEarlier));
            return;
        }

        await LoadFirstMessagePageAsync(item.Id, preserveContentOnFailure: false);
    }

    public Task RefreshMessagesAsync()
    {
        ThrowIfDisposed();
        return SelectedConversation is { IsEncrypted: false } selected
            ? LoadFirstMessagePageAsync(selected.Id, preserveContentOnFailure: true)
            : Task.CompletedTask;
    }

    public async Task LoadEarlierAsync()
    {
        ThrowIfDisposed();
        var repository = RequireRepository();
        var profile = RequireProfile();
        var selected = SelectedConversation;
        var cache = CurrentConversationCache;
        if (selected is null || selected.IsEncrypted || cache is null ||
            !cache.HasMoreBefore || IsLoadingMessages || IsLoadingEarlier)
        {
            return;
        }

        var generation = BeginMessageRequest();
        var cancellation = _messageCancellation!;
        IsLoadingEarlier = true;
        HasLoadEarlierError = false;
        try
        {
            var page = await repository.ListMessagesAsync(
                selected.Id,
                cache.PreviousCursor,
                _pageSize,
                cancellation.Token);
            if (!IsCurrentMessageRequest(generation, repository, selected.Id))
            {
                return;
            }
            MergeMessages(cache, page);
            ReplaceMessages(cache.Messages);
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
        {
        }
        catch
        {
            if (IsCurrentMessageRequest(generation, repository, selected.Id))
            {
                HasLoadEarlierError = true;
            }
        }
        finally
        {
            if (IsCurrentMessageRequest(generation, repository, selected.Id))
            {
                IsLoadingEarlier = false;
                RaisePropertyChanged(nameof(CanLoadEarlier));
            }
        }
    }

    public async Task ToggleConversationPinAsync(ChatConversationItem? item)
    {
        ThrowIfDisposed();
        if (item is null || ActiveProfileId is not Guid profileId ||
            CurrentProfile is not { Loaded: true } profile ||
            !profile.AllConversations.Any(value => value.Id == item.Id))
        {
            return;
        }

        var pins = profile.PinnedConversationIds.ToList();
        if (!pins.Remove(item.Id))
        {
            pins.Insert(0, item.Id);
        }
        profile.PinnedConversationIds = FileChatConversationPinStore.Normalize(pins);
        ApplyPinState(profile);
        ApplyConversationFilter();
        RestoreSelectedConversationReference(profile);

        try
        {
            HasPinStorageError = !await _pinStore.SaveAsync(
                profileId,
                profile.PinnedConversationIds).ConfigureAwait(true);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch
        {
            HasPinStorageError = true;
        }
    }

    private async Task LoadConversationsAsync(ProfileCache profile, bool preserveContentOnFailure)
    {
        var repository = RequireRepository();
        CancelConversationRequest();
        var generation = ++_conversationGeneration;
        var cancellation = _conversationCancellation = new CancellationTokenSource();
        IsLoadingConversations = true;
        HasConversationError = false;
        if (!preserveContentOnFailure || !profile.Loaded)
        {
            ContentState = ChatBrowserContentState.Loading;
        }
        try
        {
            var conversations = await repository.ListConversationsAsync(cancellation.Token);
            if (!IsCurrentConversationRequest(generation, repository))
            {
                return;
            }
            profile.AllConversations = SortConversations(
                conversations.Select(value => new ChatConversationItem(
                    value,
                    profile.PinnedConversationIds.Contains(value.Id, StringComparer.Ordinal))),
                profile.PinnedConversationIds);
            var encryptedIds = profile.AllConversations
                .Where(value => value.IsEncrypted)
                .Select(value => value.Id)
                .ToArray();
            foreach (var encryptedId in encryptedIds)
            {
                profile.Messages.Remove(encryptedId);
            }
            if (SelectedConversation is { } activeSelection &&
                profile.AllConversations.FirstOrDefault(value => value.Id == activeSelection.Id)
                    is not { IsEncrypted: false })
            {
                CancelMessageRequest();
            }
            profile.Loaded = true;
            ApplyConversationFilter();
            RestoreSelection(profile);
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
        {
        }
        catch
        {
            if (IsCurrentConversationRequest(generation, repository))
            {
                HasConversationError = true;
                if (!preserveContentOnFailure || Conversations.Count == 0)
                {
                    Conversations.Clear();
                    Messages.Clear();
                    SelectedConversation = null;
                    ContentState = ChatBrowserContentState.Error;
                }
            }
        }
        finally
        {
            if (IsCurrentConversationRequest(generation, repository))
            {
                IsLoadingConversations = false;
            }
        }
    }

    private async Task LoadFirstMessagePageAsync(string conversationId, bool preserveContentOnFailure)
    {
        var repository = RequireRepository();
        var profile = RequireProfile();
        var generation = BeginMessageRequest();
        var cancellation = _messageCancellation!;
        IsLoadingMessages = true;
        HasMessageError = false;
        HasLoadEarlierError = false;
        try
        {
            var page = await repository.ListMessagesAsync(
                conversationId,
                null,
                _pageSize,
                cancellation.Token);
            if (!IsCurrentMessageRequest(generation, repository, conversationId))
            {
                return;
            }
            var cache = new ConversationCache();
            profile.Messages[conversationId] = cache;
            MergeMessages(cache, page);
            ReplaceMessages(cache.Messages);
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
        {
        }
        catch
        {
            if (IsCurrentMessageRequest(generation, repository, conversationId))
            {
                HasMessageError = true;
                if (!preserveContentOnFailure)
                {
                    Messages.Clear();
                }
            }
        }
        finally
        {
            if (IsCurrentMessageRequest(generation, repository, conversationId))
            {
                IsLoadingMessages = false;
                RaisePropertyChanged(nameof(CanLoadEarlier));
            }
        }
    }

    private void ApplyConversationFilter()
    {
        var profile = CurrentProfile;
        if (profile is null || !profile.Loaded)
        {
            return;
        }
        var query = SearchQuery.Trim();
        var filtered = string.IsNullOrEmpty(query)
            ? profile.AllConversations
            : profile.AllConversations.Where(item =>
                item.Title.Contains(query, StringComparison.CurrentCultureIgnoreCase) ||
                item.Summary.Contains(query, StringComparison.CurrentCultureIgnoreCase)).ToArray();
        Conversations.Clear();
        foreach (var item in filtered)
        {
            Conversations.Add(item);
        }
        ContentState = Conversations.Count > 0
            ? ChatBrowserContentState.Content
            : string.IsNullOrEmpty(query)
                ? ChatBrowserContentState.Empty
                : ChatBrowserContentState.FilteredEmpty;
    }

    private async Task EnsurePinsLoadedAsync(Guid profileId, ProfileCache profile)
    {
        if (profile.PinsLoaded)
        {
            return;
        }
        try
        {
            profile.PinnedConversationIds = FileChatConversationPinStore.Normalize(
                await _pinStore.LoadAsync(profileId).ConfigureAwait(true));
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch
        {
            profile.PinnedConversationIds = [];
        }
        profile.PinsLoaded = true;
    }

    private ProfileCache GetOrCreateProfile(Guid profileId)
    {
        if (_profiles.TryGetValue(profileId, out var existing))
        {
            return existing;
        }
        var profile = new ProfileCache();
        _profiles[profileId] = profile;
        return profile;
    }

    private static IReadOnlyList<ChatConversationItem> SortConversations(
        IEnumerable<ChatConversationItem> conversations,
        IReadOnlyList<string> pinnedConversationIds)
    {
        var ranks = pinnedConversationIds
            .Select((id, index) => (id, index))
            .ToDictionary(value => value.id, value => value.index, StringComparer.Ordinal);
        return conversations
            .OrderBy(value => ranks.TryGetValue(value.Id, out var rank)
                ? rank
                : int.MaxValue)
            .ThenByDescending(value => value.LastActivityAt)
            .ThenBy(value => value.Title, StringComparer.CurrentCultureIgnoreCase)
            .ToArray();
    }

    private void ApplyPinState(ProfileCache profile)
    {
        var pinned = profile.PinnedConversationIds.ToHashSet(StringComparer.Ordinal);
        profile.AllConversations = SortConversations(
            profile.AllConversations.Select(value =>
            {
                var isPinned = pinned.Contains(value.Id);
                return value.IsPinned == isPinned
                    ? value
                    : value with { IsPinned = isPinned };
            }),
            profile.PinnedConversationIds);
    }

    private void RestoreSelectedConversationReference(ProfileCache profile)
    {
        if (SelectedConversation is not { } selected)
        {
            return;
        }
        var replacement = profile.AllConversations
            .FirstOrDefault(value => value.Id == selected.Id);
        if (replacement is not null && !ReferenceEquals(replacement, selected))
        {
            SelectedConversation = replacement;
        }
    }

    private void RestoreProfile(ProfileCache profile)
    {
        ResetErrors();
        ApplyConversationFilter();
        RestoreSelection(profile);
    }

    private void RestoreSelection(ProfileCache profile)
    {
        var selection = profile.SelectedConversationId is { } id
            ? Conversations.FirstOrDefault(item => item.Id == id)
            : null;
        if (SelectedConversation?.Id != selection?.Id)
        {
            CancelMessageRequest();
        }
        SelectedConversation = selection;
        Messages.Clear();
        if (selection is not null && !selection.IsEncrypted &&
            profile.Messages.TryGetValue(selection.Id, out var cache))
        {
            ReplaceMessages(cache.Messages);
        }
    }

    private static void MergeMessages(ConversationCache cache, ChatMessagePage page)
    {
        var merged = cache.Messages
            .Concat(page.Messages.Select(value => new ChatMessageItem(value)))
            .GroupBy(value => value.Id, StringComparer.Ordinal)
            .Select(group => group.First())
            .OrderBy(value => value.SentAt)
            .ThenBy(value => value.Id, StringComparer.Ordinal)
            .ToArray();
        cache.Messages = merged;
        cache.PreviousCursor = page.PreviousCursor;
        cache.HasMoreBefore = page.HasMoreBefore;
        cache.Loaded = true;
    }

    private void ReplaceMessages(IEnumerable<ChatMessageItem> messages)
    {
        Messages.Clear();
        foreach (var message in messages)
        {
            Messages.Add(message);
        }
    }

    private void SaveCurrentProfileState()
    {
        if (CurrentProfile is { } profile)
        {
            profile.SelectedConversationId = SelectedConversation?.Id;
            profile.SearchQuery = SearchQuery;
        }
    }

    private void RestoreSearchQuery(ProfileCache profile)
    {
        _searchQuery = profile.SearchQuery;
        RaisePropertyChanged(nameof(SearchQuery));
    }

    private long BeginMessageRequest()
    {
        CancelMessageRequest();
        _messageCancellation = new CancellationTokenSource();
        return _messageGeneration;
    }

    private bool IsCurrentConversationRequest(long generation, IChatRepository repository) =>
        !_disposed && generation == _conversationGeneration &&
        ReferenceEquals(repository, _repository) && ActiveProfileId == repository.ProfileId;

    private bool IsCurrentMessageRequest(long generation, IChatRepository repository, string conversationId) =>
        !_disposed && generation == _messageGeneration &&
        ReferenceEquals(repository, _repository) && ActiveProfileId == repository.ProfileId &&
        SelectedConversation?.Id == conversationId;

    private IChatRepository RequireRepository() => _repository ??
        throw new InvalidOperationException("Chat is not active for a NAS profile.");

    private ProfileCache RequireProfile() => CurrentProfile ??
        throw new InvalidOperationException("Chat is not active for a NAS profile.");

    private void CancelConversationRequest()
    {
        _conversationGeneration++;
        _conversationCancellation?.Cancel();
        _conversationCancellation?.Dispose();
        _conversationCancellation = null;
        IsLoadingConversations = false;
    }

    private void CancelMessageRequest()
    {
        _messageGeneration++;
        _messageCancellation?.Cancel();
        _messageCancellation?.Dispose();
        _messageCancellation = null;
        IsLoadingMessages = false;
        IsLoadingEarlier = false;
    }

    private void CancelAllRequests()
    {
        CancelConversationRequest();
        CancelMessageRequest();
    }

    private void ResetErrors()
    {
        HasConversationError = false;
        HasMessageError = false;
        HasLoadEarlierError = false;
        HasPinStorageError = false;
    }

    private void RaiseStateProperties()
    {
        RaisePropertyChanged(nameof(HasContent));
        RaisePropertyChanged(nameof(IsEmpty));
        RaisePropertyChanged(nameof(IsFilteredEmpty));
        RaisePropertyChanged(nameof(HasError));
        RaisePropertyChanged(nameof(IsUnavailable));
        RaisePropertyChanged(nameof(RequiresValidation));
    }

    private void ThrowIfDisposed() => ObjectDisposedException.ThrowIf(_disposed, this);

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
        _conversationGeneration++;
        _messageGeneration++;
        _conversationCancellation?.Cancel();
        _conversationCancellation?.Dispose();
        _messageCancellation?.Cancel();
        _messageCancellation?.Dispose();
        _conversationCancellation = null;
        _messageCancellation = null;
    }

    private sealed class ProfileCache
    {
        public bool Loaded { get; set; }
        public bool PinsLoaded { get; set; }
        public IReadOnlyList<ChatConversationItem> AllConversations { get; set; } = [];
        public IReadOnlyList<string> PinnedConversationIds { get; set; } = [];
        public string? SelectedConversationId { get; set; }
        public string SearchQuery { get; set; } = string.Empty;
        public Dictionary<string, ConversationCache> Messages { get; } =
            new(StringComparer.Ordinal);
    }

    private sealed class ConversationCache
    {
        public bool Loaded { get; set; }
        public IReadOnlyList<ChatMessageItem> Messages { get; set; } = [];
        public string? PreviousCursor { get; set; }
        public bool HasMoreBefore { get; set; }
    }
}
