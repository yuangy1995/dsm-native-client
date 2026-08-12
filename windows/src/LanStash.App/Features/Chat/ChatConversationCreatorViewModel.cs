using System.Collections.ObjectModel;
using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.Chat;

public enum ChatConversationCreatorContentState
{
    Loading,
    Empty,
    Error,
    Content,
}

public sealed class ChatConversationCreatorViewModel : ObservableObject, IDisposable
{
    private readonly IChatRepository _repository;
    private CancellationTokenSource? _loadCancellation;
    private string? _pendingSignature;
    private Guid _pendingRequestId;
    private string? _pendingDirectUserId;
    private string? _pendingGroupTitle;
    private IReadOnlyList<string> _pendingGroupMemberIds = [];
    private ChatConversationCreatorContentState _contentState =
        ChatConversationCreatorContentState.Loading;
    private bool _isSubmitting;
    private bool _disposed;

    public ChatConversationCreatorViewModel(IChatRepository repository)
    {
        ArgumentNullException.ThrowIfNull(repository);
        _repository = repository;
    }

    public ObservableCollection<ChatUser> Users { get; } = [];

    public ChatConversationCreatorContentState ContentState
    {
        get => _contentState;
        private set => SetProperty(ref _contentState, value);
    }

    public bool IsSubmitting
    {
        get => _isSubmitting;
        private set => SetProperty(ref _isSubmitting, value);
    }

    public bool CanCreateDirect =>
        _repository.Availability.SupportedWriteFeatures.Contains(
            ChatWriteFeature.DirectConversation);

    public bool CanCreatePrivateGroup =>
        _repository.Availability.SupportedWriteFeatures.Contains(ChatWriteFeature.PrivateGroup);

    public bool RequiresReview => _pendingSignature is not null;
    public string? PendingDirectUserId => _pendingDirectUserId;
    public string? PendingGroupTitle => _pendingGroupTitle;
    public IReadOnlyList<string> PendingGroupMemberIds => _pendingGroupMemberIds;
    public bool PendingIsGroup => _pendingGroupTitle is not null;

    public async Task LoadAsync()
    {
        ThrowIfDisposed();
        _loadCancellation?.Cancel();
        _loadCancellation?.Dispose();
        var cancellation = _loadCancellation = new CancellationTokenSource();
        ContentState = ChatConversationCreatorContentState.Loading;
        try
        {
            var users = await _repository.ListUsersAsync(cancellation.Token);
            if (_disposed || !ReferenceEquals(cancellation, _loadCancellation))
            {
                return;
            }
            Users.Clear();
            foreach (var user in users
                         .Where(user => !user.IsDisabled && user.IsCurrentUser != true)
                         .OrderBy(user => user.DisplayName, StringComparer.CurrentCultureIgnoreCase)
                         .ThenBy(user => user.Id, StringComparer.Ordinal))
            {
                Users.Add(user);
            }
            ContentState = Users.Count == 0
                ? ChatConversationCreatorContentState.Empty
                : ChatConversationCreatorContentState.Content;
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
        {
        }
        catch
        {
            if (!_disposed && ReferenceEquals(cancellation, _loadCancellation))
            {
                Users.Clear();
                ContentState = ChatConversationCreatorContentState.Error;
            }
        }
    }

    public void CancelLoad()
    {
        ThrowIfDisposed();
        _loadCancellation?.Cancel();
    }

    public Task<ChatConversationCreateOutcome> CreateDirectAsync(string userId) =>
        CreateAsync(
            $"direct\0{userId.Trim()}",
            pendingDirectUserId: userId.Trim(),
            pendingGroupTitle: null,
            pendingGroupMemberIds: [],
            requestId => _repository.OpenDirectConversationAsync(
                new ChatDirectConversationRequest(userId, requestId)));

    public Task<ChatConversationCreateOutcome> CreatePrivateGroupAsync(
        string title,
        IReadOnlyList<string> memberIds)
    {
        var normalizedTitle = title.Trim();
        var normalizedMembers = memberIds
            .Select(value => value.Trim())
            .Where(value => value.Length > 0)
            .Distinct(StringComparer.Ordinal)
            .Order(StringComparer.Ordinal)
            .ToArray();
        var signature = $"group\0{normalizedTitle}\0{string.Join('\0', normalizedMembers)}";
        return CreateAsync(
            signature,
            pendingDirectUserId: null,
            pendingGroupTitle: normalizedTitle,
            pendingGroupMemberIds: normalizedMembers,
            requestId => _repository.CreatePrivateGroupAsync(
                new ChatPrivateGroupCreateRequest(normalizedTitle, normalizedMembers, requestId)));
    }

    private async Task<ChatConversationCreateOutcome> CreateAsync(
        string signature,
        string? pendingDirectUserId,
        string? pendingGroupTitle,
        IReadOnlyList<string> pendingGroupMemberIds,
        Func<Guid, Task<ChatConversationCreateOutcome>> submit)
    {
        ThrowIfDisposed();
        if (IsSubmitting)
        {
            throw new InvalidOperationException("A Chat conversation creation is already running.");
        }
        if (_pendingSignature is not null &&
            !string.Equals(_pendingSignature, signature, StringComparison.Ordinal))
        {
            throw new InvalidOperationException("The pending Chat creation must be reviewed first.");
        }

        var requestId = _pendingSignature is null ? Guid.NewGuid() : _pendingRequestId;
        IsSubmitting = true;
        try
        {
            var outcome = await submit(requestId);
            if (outcome.Result.Status is MutationResultStatus.SubmittedButUnverified or
                MutationResultStatus.CancellationRequestedAfterSubmission)
            {
                _pendingSignature = signature;
                _pendingRequestId = requestId;
                _pendingDirectUserId = pendingDirectUserId;
                _pendingGroupTitle = pendingGroupTitle;
                _pendingGroupMemberIds = pendingGroupMemberIds;
            }
            else
            {
                _pendingSignature = null;
                _pendingRequestId = Guid.Empty;
                _pendingDirectUserId = null;
                _pendingGroupTitle = null;
                _pendingGroupMemberIds = [];
            }
            RaisePropertyChanged(nameof(RequiresReview));
            return outcome;
        }
        finally
        {
            IsSubmitting = false;
        }
    }

    private void ThrowIfDisposed()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
        _loadCancellation?.Cancel();
        _loadCancellation?.Dispose();
        _loadCancellation = null;
    }
}
