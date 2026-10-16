using LanStash.App.Localization;
using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.Downloads;

public sealed record DownloadRecoveryRow(DownloadActionInfo Action)
{
    public string Title => LocalizationService.Current.Format("DownloadActionTitle", LocalizationService.Current.Get(Action.Kind switch
    {
        DownloadActionKind.CreateLink => "DownloadActionCreateLink", DownloadActionKind.CreateFile => "DownloadActionCreateFile",
        DownloadActionKind.Pause => "DownloadActionPause", DownloadActionKind.Resume => "DownloadActionResume", DownloadActionKind.Remove => "DownloadActionRemove",
        DownloadActionKind.FinishIncomplete => "DownloadActionFinishIncomplete", DownloadActionKind.EditDestination => "DownloadActionEditDestination",
        DownloadActionKind.RefreshRss => "DownloadActionRefreshRss", _ => "DownloadActionSettings",
    }), Action.CreatedAt.ToLocalTime().ToString("g"));
}
public sealed record DownloadRecoveryItem(string Title, string State);
public sealed class DownloadRecoveryModel(IDownloadStationRepository repository) : ObservableObject, IDisposable
{
    private CancellationTokenSource? _cancellation;
    private long _generation;
    private bool _disposed;
    public bool IsBusy { get; private set; }
    public bool HasError { get; private set; }
    public IReadOnlyList<DownloadRecoveryRow> Rows { get; private set; } = [];
    public DownloadActionInfo? Selected { get; private set; }
    public IReadOnlyList<DownloadRecoveryItem> Items => Selected?.Items.Select((item, index) => new DownloadRecoveryItem(
        item.Task?.Title ?? LocalizationService.Current.Format("DownloadActionItem", index + 1),
        LocalizationService.Current.Get(item.Stage switch
        {
            DownloadActionStage.NotStarted => "DownloadActionStageNotStarted", DownloadActionStage.Unknown => "DownloadActionStageUnknown",
            DownloadActionStage.Accepted => "DownloadActionStageAccepted", DownloadActionStage.Confirmed => "DownloadActionStageConfirmed",
            DownloadActionStage.Cancelled => "DownloadActionStageCancelled", _ => "DownloadActionStageRejected",
        }))).ToArray() ?? [];
    public bool CanReview => !IsBusy && !HasError && Selected?.RequiresReview == true;
    public bool CanContinue => !IsBusy && !HasError && Selected?.CanContinue == true;
    public bool CanCancel => !IsBusy && !HasError && Selected?.CanCancelRemaining == true;
    public bool NeedsDangerConfirmation => Selected?.Kind is DownloadActionKind.Remove or DownloadActionKind.FinishIncomplete;
    public string? NoticeKey => Selected?.Kind switch
    {
        DownloadActionKind.CreateLink or DownloadActionKind.CreateFile when Selected.RequiresReview => "DownloadActionCreateUnknown",
        DownloadActionKind.Remove => "DownloadBatchRemoveWarning",
        DownloadActionKind.FinishIncomplete => "DownloadBatchFinishWarning",
        DownloadActionKind.EditDestination => "DownloadEditDestinationHint",
        _ => null,
    };
    public void Select(DownloadRecoveryRow? row)
    { if (_disposed || IsBusy) return; Selected = row is null ? null : Rows.FirstOrDefault(item => item.Action.Id == row.Action.Id)?.Action; RaisePropertyChanged(string.Empty); }
    public Task LoadAsync() => RunAsync(null);
    public Task ReviewAsync() => CanReview ? RunAsync((id, token) => repository.ReviewDownloadActionAsync(id, token)) : Task.CompletedTask;
    public Task ContinueAsync() => CanContinue ? RunAsync((id, token) => repository.ContinueDownloadActionAsync(id, token)) : Task.CompletedTask;
    public Task CancelAsync() => CanCancel ? RunAsync((id, token) => repository.CancelDownloadActionRemainderAsync(id, token)) : Task.CompletedTask;
    private async Task RunAsync(Func<Guid, CancellationToken, Task<DownloadActionInfo>>? action)
    {
        if (_disposed || IsBusy) return;
        var selection = Selected?.Id; var generation = ++_generation;
        using var cancellation = _cancellation = new CancellationTokenSource();
        IsBusy = true; HasError = false; RaisePropertyChanged(string.Empty);
        try
        {
            if (action is not null && selection is { } id)
            {
                var result = await action(id, cancellation.Token);
                if (result.Id != id || result.ProfileId != repository.ProfileId) throw new InvalidDataException("download.recovery.foreign-result");
            }
            var rows = await repository.LoadDownloadActionsAsync(cancellation.Token);
            if (generation != _generation) return;
            if (rows.Any(row => row.ProfileId != repository.ProfileId) || rows.Select(row => row.Id).Distinct().Count() != rows.Count)
                throw new InvalidDataException("download.recovery.foreign-list");
            Rows = rows.Select(row => new DownloadRecoveryRow(row)).ToArray();
            Selected = rows.FirstOrDefault(row => row.Id == selection) ?? rows.FirstOrDefault(row => row.IsPending) ?? rows.FirstOrDefault();
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
        catch { if (generation == _generation) HasError = true; }
        finally { if (generation == _generation) { _cancellation = null; IsBusy = false; RaisePropertyChanged(string.Empty); } }
    }
    public void Dispose() { _disposed = true; ++_generation; _cancellation?.Cancel(); _cancellation = null; }
}
