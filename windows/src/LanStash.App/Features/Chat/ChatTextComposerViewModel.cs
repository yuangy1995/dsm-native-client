using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.Chat;

public enum ChatTextComposerState
{
    Unavailable,
    Ready,
    Sending,
    Sent,
    NeedsReview,
    CancelledBeforeSubmission,
    PermissionDenied,
    Failure,
}

public sealed class ChatTextComposerViewModel : ObservableObject, IDisposable
{
    private readonly ChatTextSendReviewBlocker _blocker;
    private readonly Dictionary<(Guid ProfileId, string ConversationId), string> _drafts = [];
    private IChatRepository? _repository;
    private ChatConversationItem? _conversation;
    private CancellationTokenSource? _request;
    private ChatTextComposerState _state = ChatTextComposerState.Unavailable;
    private string _draftText = string.Empty;
    private long _generation;
    private bool _disposed;

    public ChatTextComposerViewModel(ChatTextSendReviewBlocker blocker)
    {
        ArgumentNullException.ThrowIfNull(blocker);
        _blocker = blocker;
    }

    public ChatTextComposerState State
    {
        get => _state;
        private set
        {
            if (SetProperty(ref _state, value))
            {
                RaiseStateProperties();
            }
        }
    }

    public string DraftText
    {
        get => _draftText;
        set
        {
            var next = value ?? string.Empty;
            if (SetProperty(ref _draftText, next))
            {
                SaveDraft();
                if (State is ChatTextComposerState.NeedsReview or
                    ChatTextComposerState.Sent or
                    ChatTextComposerState.CancelledBeforeSubmission or
                    ChatTextComposerState.PermissionDenied or
                    ChatTextComposerState.Failure)
                {
                    State = CanUseCurrentConversation
                        ? ChatTextComposerState.Ready
                        : ChatTextComposerState.Unavailable;
                }
                RaiseStateProperties();
            }
        }
    }

    public bool IsAvailable => CanUseCurrentConversation;
    public bool IsSending => State == ChatTextComposerState.Sending;
    public bool CanEdit => IsAvailable && !IsSending;
    public bool HasReview => State == ChatTextComposerState.NeedsReview;
    public bool HasStatus => State is ChatTextComposerState.Sending or
        ChatTextComposerState.Sent or
        ChatTextComposerState.NeedsReview or
        ChatTextComposerState.CancelledBeforeSubmission or
        ChatTextComposerState.PermissionDenied or
        ChatTextComposerState.Failure;
    public bool CanSend => CanEdit &&
        !string.IsNullOrWhiteSpace(NormalizedDraft) &&
        CurrentReviewBlock is null;

    public void Configure(IChatRepository repository, ChatConversationItem? conversation)
    {
        ThrowIfDisposed();
        ArgumentNullException.ThrowIfNull(repository);
        var changed = !ReferenceEquals(repository, _repository) ||
            _conversation?.Id != conversation?.Id;
        if (changed)
        {
            SaveDraft();
            CancelRequest();
            _repository = repository;
            _conversation = conversation;
            _draftText = LoadDraft();
            State = CanUseCurrentConversation
                ? ChatTextComposerState.Ready
                : ChatTextComposerState.Unavailable;
            RaisePropertyChanged(nameof(DraftText));
        }
        else
        {
            State = CanUseCurrentConversation
                ? State == ChatTextComposerState.Unavailable
                    ? ChatTextComposerState.Ready
                    : State
                : ChatTextComposerState.Unavailable;
        }
        RaiseStateProperties();
    }

    public void Deactivate()
    {
        if (_disposed)
        {
            return;
        }
        SaveDraft();
        CancelRequest();
        _repository = null;
        _conversation = null;
        _draftText = string.Empty;
        State = ChatTextComposerState.Unavailable;
        RaisePropertyChanged(nameof(DraftText));
    }

    public async Task<bool> SendAsync()
    {
        ThrowIfDisposed();
        if (!CanSend || _repository is null || _conversation is null)
        {
            return false;
        }
        var normalizedText = NormalizedDraft;
        var review = CurrentReviewBlock;
        if (review is not null)
        {
            State = ChatTextComposerState.NeedsReview;
            return false;
        }

        var generation = BeginRequest(out var cancellation);
        State = ChatTextComposerState.Sending;
        try
        {
            var outcome = await _repository.SendTextAsync(
                new ChatTextSendRequest(
                    _conversation.Id,
                    normalizedText,
                    Guid.NewGuid()),
                cancellation.Token);
            if (!IsCurrent(generation))
            {
                return false;
            }
            return Apply(outcome, normalizedText);
        }
        catch (OperationCanceledException) when (IsCurrent(generation))
        {
            MarkReview(normalizedText);
            return false;
        }
        catch when (IsCurrent(generation))
        {
            MarkReview(normalizedText);
            return false;
        }
        finally
        {
            EndRequest(cancellation);
        }
    }

    private bool Apply(ChatTextSendOutcome outcome, string normalizedText)
    {
        if (outcome.Result.Status == MutationResultStatus.ConfirmedSuccess &&
            outcome.ConfirmedMessage is not null &&
            _conversation is not null &&
            string.Equals(outcome.ConversationId, _conversation.Id, StringComparison.Ordinal))
        {
            ClearReview(normalizedText);
            DraftText = string.Empty;
            State = ChatTextComposerState.Sent;
            return true;
        }
        switch (outcome.Result.Status)
        {
            case MutationResultStatus.CancelledBeforeSubmission:
                State = ChatTextComposerState.CancelledBeforeSubmission;
                break;
            case MutationResultStatus.PermissionDenied:
                State = ChatTextComposerState.PermissionDenied;
                break;
            case MutationResultStatus.Unsupported:
                State = ChatTextComposerState.Unavailable;
                break;
            case MutationResultStatus.SubmittedButUnverified:
            case MutationResultStatus.CancellationRequestedAfterSubmission:
                MarkReview(normalizedText);
                break;
            default:
                State = ChatTextComposerState.Failure;
                break;
        }
        return false;
    }

    private bool CanUseCurrentConversation =>
        _repository is { Availability.Status: ChatAvailabilityStatus.Available } repository &&
        repository.Availability.SupportedWriteFeatures.Contains(ChatWriteFeature.TextMessage) &&
        _conversation is { IsEncrypted: false };

    private string NormalizedDraft => DraftText.Trim();

    private ChatTextSendReviewBlock? CurrentReviewBlock =>
        _repository is null || _conversation is null || string.IsNullOrWhiteSpace(NormalizedDraft)
            ? null
            : _blocker.Find(_repository.ProfileId, _conversation.Id, NormalizedDraft);

    private void MarkReview(string normalizedText)
    {
        if (_repository is null || _conversation is null)
        {
            State = ChatTextComposerState.Failure;
            return;
        }
        _blocker.Block(new(_repository.ProfileId, _conversation.Id, normalizedText));
        State = ChatTextComposerState.NeedsReview;
    }

    private void ClearReview(string normalizedText)
    {
        if (_repository is null || _conversation is null)
        {
            return;
        }
        if (_blocker.Find(_repository.ProfileId, _conversation.Id, normalizedText) is { } review)
        {
            _blocker.Clear(review);
        }
    }

    private void SaveDraft()
    {
        if (_repository is null || _conversation is null)
        {
            return;
        }
        _drafts[(_repository.ProfileId, _conversation.Id)] = DraftText;
    }

    private string LoadDraft() =>
        _repository is not null &&
        _conversation is not null &&
        _drafts.TryGetValue((_repository.ProfileId, _conversation.Id), out var draft)
            ? draft
            : string.Empty;

    private long BeginRequest(out CancellationTokenSource cancellation)
    {
        CancelRequest();
        cancellation = _request = new CancellationTokenSource();
        return _generation;
    }

    private void CancelRequest()
    {
        _generation++;
        _request?.Cancel();
        _request?.Dispose();
        _request = null;
        if (State == ChatTextComposerState.Sending)
        {
            State = ChatTextComposerState.Ready;
        }
    }

    private void EndRequest(CancellationTokenSource cancellation)
    {
        if (ReferenceEquals(_request, cancellation))
        {
            _request = null;
        }
        cancellation.Dispose();
        RaiseStateProperties();
    }

    private bool IsCurrent(long generation) =>
        !_disposed && generation == _generation;

    private void RaiseStateProperties()
    {
        RaisePropertyChanged(nameof(IsAvailable));
        RaisePropertyChanged(nameof(IsSending));
        RaisePropertyChanged(nameof(CanEdit));
        RaisePropertyChanged(nameof(HasReview));
        RaisePropertyChanged(nameof(HasStatus));
        RaisePropertyChanged(nameof(CanSend));
    }

    private void ThrowIfDisposed() => ObjectDisposedException.ThrowIf(_disposed, this);

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
        CancelRequest();
        _drafts.Clear();
        _repository = null;
        _conversation = null;
    }
}
