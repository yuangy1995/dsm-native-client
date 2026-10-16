using LanStash.Domain;

namespace LanStash.App.Features.VirtualMachines;

public sealed partial class VirtualMachineManagerViewModel
{
    private CancellationTokenSource? _activityCancellation;
    private long _activityGeneration;
    private bool _activityVisible;
    private IReadOnlyList<VirtualMachineEventItem> _activityItems = [];
    public bool IsActivityLoading { get; private set; }
    public bool ActivityReadFailed { get; private set; }
    public string ActivitySearch { get; private set; } = "";
    public ServiceEventLevel? ActivityLevel { get; private set; }

    public Task SetActivityVisibleAsync(bool visible)
    {
        if (_disposed || _activityVisible == visible) return Task.CompletedTask;
        if (!visible) { ClearActivity(); return Task.CompletedTask; }
        _activityVisible = true;
        return RefreshActivityAsync();
    }

    public void SetActivityFilter(string search, ServiceEventLevel? level)
    {
        if (_disposed || !_activityVisible) return;
        ActivitySearch = search; ActivityLevel = level;
        if (!IsActivityLoading && EventsState is VirtualMachineManagerContentState.Content or VirtualMachineManagerContentState.Empty or VirtualMachineManagerContentState.FilteredEmpty)
            ApplyActivityFilter();
        RaisePropertyChanged(string.Empty);
    }

    private async Task RefreshActivityAsync()
    {
        if (!_activityVisible || _disposed || _repository is null || IsActivityLoading || RequiresReconnect) return;
        var repository = _repository;
        if (!repository.Availability.Features.Contains(VirtualMachineManagerReadFeature.Events))
        { EventsState = VirtualMachineManagerContentState.Unavailable; return; }
        var generation = ++_activityGeneration;
        var cancellation = _activityCancellation = new();
        IsActivityLoading = true; ActivityReadFailed = false; EventsState = VirtualMachineManagerContentState.Loading;
        RaisePropertyChanged(string.Empty);
        bool Current() => !_disposed && _activityVisible && generation == _activityGeneration && ReferenceEquals(repository, _repository);
        try
        {
            var section = await repository.LoadActivityAsync(cancellation.Token);
            if (!Current()) return;
            if (section.Status == VirtualMachineManagerSectionStatus.Available)
            {
                _activityItems = section.Items.Select(item => new VirtualMachineEventItem(item.Summary) { Activity = item }).ToArray();
                ApplyActivityFilter();
            }
            else if (section.Status == VirtualMachineManagerSectionStatus.Unavailable)
            { _activityItems = []; Events.Clear(); EventsState = VirtualMachineManagerContentState.Unavailable; }
            else ReadFailed();
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
        catch (Exception error)
        {
            if (!Current()) return;
            RequiresReconnect |= error is CertificateTrustChallengeException || error is DsmException dsm && IsAuthenticationFailure(dsm);
            ReadFailed();
        }
        finally
        {
            if (Current()) { IsActivityLoading = false; _activityCancellation = null; RaisePropertyChanged(string.Empty); }
            cancellation.Dispose();
        }
        void ReadFailed()
        {
            ActivityReadFailed = true;
            if (_activityItems.Count > 0) ApplyActivityFilter(); else EventsState = VirtualMachineManagerContentState.Error;
        }
    }

    private void ApplyActivityFilter()
    {
        var search = ActivitySearch.Trim();
        var filtered = _activityItems.Where(item => (ActivityLevel is null || item.Event.Level == ActivityLevel) &&
            (search.Length == 0 || item.Message.Contains(search, StringComparison.CurrentCultureIgnoreCase) ||
             item.Account.Contains(search, StringComparison.CurrentCultureIgnoreCase))).ToArray();
        Replace(Events, filtered);
        EventsState = _activityItems.Count == 0 ? VirtualMachineManagerContentState.Empty : filtered.Length == 0
            ? VirtualMachineManagerContentState.FilteredEmpty : VirtualMachineManagerContentState.Content;
    }

    private void ClearActivity()
    {
        _activityGeneration++; _activityVisible = false;
        var previous = _activityCancellation; _activityCancellation = null; previous?.Cancel();
        _activityItems = []; Events.Clear(); IsActivityLoading = ActivityReadFailed = false;
        ActivitySearch = ""; ActivityLevel = null; RaisePropertyChanged(string.Empty);
    }
}
