using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.Chat;

public enum ChatAttachmentComposerState
{
    Unavailable,
    Ready,
    Selected,
    Sending,
    Sent,
    NeedsReview,
    CancelledBeforeSubmission,
    PermissionDenied,
    Failure,
}

/// <summary>
/// 单附件前台发送状态。文件选择器和本机路径由 WinUI partial 持有，本类型只接收可重开的内容源。
/// </summary>
public sealed class ChatAttachmentComposerViewModel : ObservableObject, IDisposable
{
    private readonly ChatAttachmentSendReviewBlocker _blocker;
    private IChatRepository? _repository;
    private ChatConversationItem? _conversation;
    private CancellationTokenSource? _request;
    private ChatAttachmentDraft? _draft;
    private ChatAttachmentSendRequest? _pendingRequest;
    private readonly Dictionary<(Guid Profile, string? Account, string Conversation), SavedDraft> _drafts = [];
    private ChatAttachmentComposerState _state = ChatAttachmentComposerState.Unavailable;
    private long? _completedBytes;
    private long _generation;
    private bool _disposed;

    public ChatAttachmentComposerViewModel(ChatAttachmentSendReviewBlocker blocker)
    {
        ArgumentNullException.ThrowIfNull(blocker);
        _blocker = blocker;
    }

    public ChatAttachmentComposerState State
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

    public ChatAttachmentDraft? Draft
    {
        get => _draft;
        private set
        {
            if (SetProperty(ref _draft, value))
            {
                RaiseStateProperties();
            }
        }
    }

    public long? CompletedBytes
    {
        get => _completedBytes;
        private set => SetProperty(ref _completedBytes, value);
    }

    public bool IsAvailable => CanUseCurrentConversation;
    public bool IsSending => State == ChatAttachmentComposerState.Sending;
    internal bool HasDrafts => Draft is not null || _drafts.Values.Any(item => item.Draft is not null);
    public bool CanSelect => IsAvailable && !IsSending && !HasReview;
    public bool CanRemove => Draft is not null && !IsSending;
    public bool CanSend => Draft is not null &&
        CanSelect &&
        (CurrentReview is not { } review || !_blocker.Contains(review));
    public bool HasReview => State == ChatAttachmentComposerState.NeedsReview;
    public bool CanRefreshSend => IsAvailable && !IsSending && HasReview && _pendingRequest is not null && Draft is not null;
    public bool HasStatus => State is ChatAttachmentComposerState.Sending or
        ChatAttachmentComposerState.Sent or
        ChatAttachmentComposerState.NeedsReview or
        ChatAttachmentComposerState.CancelledBeforeSubmission or
        ChatAttachmentComposerState.PermissionDenied or
        ChatAttachmentComposerState.Failure;

    public void Configure(IChatRepository repository, ChatConversationItem? conversation)
    {
        ThrowIfDisposed();
        ArgumentNullException.ThrowIfNull(repository);
        var changed = !ReferenceEquals(repository, _repository) ||
            _conversation?.Id != conversation?.Id;
        if (changed)
        {
            CancelRequest(markReview: IsSending);
            SaveDraft();
            _repository = repository;
            _conversation = conversation;
            var saved = conversation is null ? null : _drafts.GetValueOrDefault((repository.ProfileId, repository.AccountIdentity, conversation.Id));
            Draft = saved?.Draft;
            _pendingRequest = saved?.Request;
            CompletedBytes = null;
            State = CanUseCurrentConversation
                ? saved?.State ?? ChatAttachmentComposerState.Ready
                : ChatAttachmentComposerState.Unavailable;
        }
        else if (!CanUseCurrentConversation)
        {
            State = ChatAttachmentComposerState.Unavailable;
        }
        else if (State == ChatAttachmentComposerState.Unavailable)
        {
            State = ChatAttachmentComposerState.Ready;
        }
        RaiseStateProperties();
    }

    public bool Select(ChatAttachmentDraft draft)
    {
        ThrowIfDisposed();
        ArgumentNullException.ThrowIfNull(draft);
        if (!CanSelect ||
            (CurrentReview is { } review && _blocker.Contains(review)) ||
            !draft.IsValid)
        {
            return false;
        }

        Draft = draft;
        _pendingRequest = null;
        CompletedBytes = null;
        var target = CurrentReview;
        State = target is not null && _blocker.Contains(target)
            ? ChatAttachmentComposerState.NeedsReview
            : ChatAttachmentComposerState.Selected;
        return true;
    }

    public void Remove()
    {
        if (!CanRemove)
        {
            return;
        }
        Draft = null;
        _pendingRequest = null;
        CompletedBytes = null;
        State = CanUseCurrentConversation
            ? ChatAttachmentComposerState.Ready
            : ChatAttachmentComposerState.Unavailable;
    }

    public async Task<bool> SendAsync(string? caption)
    {
        ThrowIfDisposed();
        if (!CanSend || _repository is null || _conversation is null || Draft is not { } draft)
        {
            return false;
        }

        var review = new ChatAttachmentSendReviewTarget(
            _repository.ProfileId,
            _conversation.Id,
            draft.Fingerprint, _repository.AccountIdentity);
        if (_blocker.Contains(review))
        {
            State = ChatAttachmentComposerState.NeedsReview;
            return false;
        }

        var generation = BeginRequest(out var cancellation);
        State = ChatAttachmentComposerState.Sending;
        CompletedBytes = 0;
        var normalizedCaption = string.IsNullOrWhiteSpace(caption) ? null : caption.Trim();
        _pendingRequest = new(_conversation.Id, normalizedCaption, draft.ToSource(), Guid.NewGuid());
        var progress = new Progress<long>(value =>
        {
            if (IsCurrent(generation))
            {
                CompletedBytes = Math.Clamp(value, 0, draft.Length);
            }
        });
        try
        {
            var outcome = await _repository.SendAttachmentAsync(
                _pendingRequest,
                progress,
                cancellation.Token);
            if (!IsCurrent(generation))
            {
                return false;
            }
            return Apply(outcome, review, draft, normalizedCaption);
        }
        catch (OperationCanceledException) when (IsCurrent(generation))
        {
            MarkReview(review);
            return false;
        }
        catch when (IsCurrent(generation))
        {
            MarkReview(review);
            return false;
        }
        finally
        {
            EndRequest(cancellation);
        }
    }

    public async Task<bool> RefreshSendAsync()
    {
        ThrowIfDisposed();
        if (!CanRefreshSend || _repository is null || Draft is not { } draft || _pendingRequest is not { } request || CurrentReview is not { } review) return false;
        var generation = BeginRequest(out var cancellation);
        State = ChatAttachmentComposerState.Sending;
        try
        {
            var outcome = await _repository.SendAttachmentAsync(request, cancellationToken: cancellation.Token);
            return IsCurrent(generation) && Apply(outcome, review, draft, request.Text);
        }
        catch when (IsCurrent(generation)) { MarkReview(review); return false; }
        finally { EndRequest(cancellation); }
    }

    public void Cancel()
    {
        if (IsSending)
        {
            _request?.Cancel();
        }
    }

    public void Deactivate()
    {
        if (_disposed)
        {
            return;
        }
        CancelRequest(markReview: IsSending);
        SaveDraft();
        _repository = null;
        _conversation = null;
        _pendingRequest = null;
        Draft = null;
        CompletedBytes = null;
        State = ChatAttachmentComposerState.Unavailable;
    }

    private bool Apply(
        ChatAttachmentSendOutcome outcome,
        ChatAttachmentSendReviewTarget review,
        ChatAttachmentDraft draft,
        string? normalizedCaption)
    {
        if (outcome.Result.Status == MutationResultStatus.ConfirmedSuccess &&
            outcome.ConfirmedMessage is { } message &&
            _conversation is not null &&
            string.Equals(outcome.ConversationId, _conversation.Id, StringComparison.Ordinal) &&
            message.ConversationId == _conversation.Id &&
            string.Equals(message.Text, normalizedCaption, StringComparison.Ordinal) &&
            message.Attachments.Count == 1 &&
            string.Equals(message.Attachments[0].FileName, draft.FileName, StringComparison.Ordinal) &&
            message.Attachments[0].SizeBytes == draft.Length)
        {
            _blocker.Clear(review);
            _pendingRequest = null;
            Draft = null;
            CompletedBytes = null;
            State = ChatAttachmentComposerState.Sent;
            return true;
        }

        if (outcome.Result.Status == MutationResultStatus.ConfirmedSuccess)
        {
            MarkReview(review);
            return false;
        }

        switch (outcome.Result.Status)
        {
            case MutationResultStatus.CancelledBeforeSubmission:
                State = ChatAttachmentComposerState.CancelledBeforeSubmission;
                break;
            case MutationResultStatus.PermissionDenied:
                State = ChatAttachmentComposerState.PermissionDenied;
                break;
            case MutationResultStatus.Unsupported:
                State = ChatAttachmentComposerState.Unavailable;
                break;
            case MutationResultStatus.SubmittedButUnverified:
            case MutationResultStatus.CancellationRequestedAfterSubmission:
                MarkReview(review);
                break;
            default:
                State = ChatAttachmentComposerState.Failure;
                break;
        }
        if (!HasReview) _pendingRequest = null;
        return false;
    }

    private bool CanUseCurrentConversation =>
        _repository is { Availability.Status: ChatAvailabilityStatus.Available } repository &&
        repository.Availability.SupportedWriteFeatures.Contains(ChatWriteFeature.AttachmentMessage) &&
        _conversation is { IsEncrypted: false };

    private ChatAttachmentSendReviewTarget? CurrentReview =>
        _repository is null || _conversation is null || Draft is null
            ? null
            : new ChatAttachmentSendReviewTarget(
                _repository.ProfileId,
                _conversation.Id,
                Draft.Fingerprint, _repository.AccountIdentity);

    private void SaveDraft()
    {
        if (_repository is null || _conversation is null) return;
        var key = (_repository.ProfileId, _repository.AccountIdentity, _conversation.Id);
        if (Draft is null) _drafts.Remove(key);
        else _drafts[key] = new(Draft, _pendingRequest, State);
    }
    private sealed record SavedDraft(ChatAttachmentDraft Draft, ChatAttachmentSendRequest? Request, ChatAttachmentComposerState State);

    private void MarkReview(ChatAttachmentSendReviewTarget target)
    {
        _blocker.Block(target);
        State = ChatAttachmentComposerState.NeedsReview;
    }

    private long BeginRequest(out CancellationTokenSource cancellation)
    {
        CancelRequest(markReview: false);
        cancellation = _request = new CancellationTokenSource();
        return _generation;
    }

    private void CancelRequest(bool markReview)
    {
        _generation++;
        _request?.Cancel();
        _request?.Dispose();
        _request = null;
        if (markReview && CurrentReview is { } review)
        {
            MarkReview(review);
        }
        else if (State == ChatAttachmentComposerState.Sending)
        {
            State = Draft is null
                ? ChatAttachmentComposerState.Ready
                : ChatAttachmentComposerState.Selected;
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

    private bool IsCurrent(long generation) => !_disposed && generation == _generation;

    private void RaiseStateProperties()
    {
        RaisePropertyChanged(nameof(IsAvailable));
        RaisePropertyChanged(nameof(IsSending));
        RaisePropertyChanged(nameof(CanSelect));
        RaisePropertyChanged(nameof(CanRemove));
        RaisePropertyChanged(nameof(CanSend));
        RaisePropertyChanged(nameof(HasReview));
        RaisePropertyChanged(nameof(HasStatus));
        RaisePropertyChanged(nameof(CanRefreshSend));
    }

    private void ThrowIfDisposed() => ObjectDisposedException.ThrowIf(_disposed, this);

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        var markReview = IsSending;
        CancelRequest(markReview);
        _disposed = true;
        _repository = null;
        _conversation = null;
        _draft = null;
    }
}

public sealed record ChatAttachmentDraft(
    string FileName,
    string? MediaType,
    long Length,
    Func<CancellationToken, Task<Stream>> OpenReadAsync)
{
    public bool IsValid => !string.IsNullOrWhiteSpace(FileName) &&
        Length >= 0 &&
        OpenReadAsync is not null;

    public string Fingerprint => $"{FileName}\u001f{MediaType ?? string.Empty}\u001f{Length}";

    public ChatAttachmentSource ToSource() =>
        new(FileName, MediaType, Length, OpenReadAsync);
}
