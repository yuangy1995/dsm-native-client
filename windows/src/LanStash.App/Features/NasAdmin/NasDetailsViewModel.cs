using System.Collections.ObjectModel;
using System.IO;
using LanStash.App.Localization;
using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.NasAdmin;

public sealed class NasDetailsViewModel : ObservableObject, IDisposable
{
    private const int MaximumCachedProfiles = 4;
    private readonly Dictionary<Guid, NasDetailsProfileState> _profiles = [];
    private readonly LinkedList<Guid> _profileOrder = [];
    private INasDetailsRepository? _repository;
    private CancellationTokenSource? _requestCancellation;
    private long _generation;
    private Guid? _activeProfileId;
    private NasDetailsContentState _contentState = NasDetailsContentState.Loading;
    private NasDetailsSectionKind _selectedSection = NasDetailsSectionKind.Packages;
    private bool _isLoading;
    private bool _hasRefreshError;
    private bool _sectionNoticeIsOpen;
    private string _sectionNoticeTitle = string.Empty;
    private string _sectionNoticeMessage = string.Empty;
    private bool _disposed;

    public ObservableCollection<NasDetailsSectionOption> Sections { get; } = [];
    public ObservableCollection<NasDetailsRow> Rows { get; } = [];

    public Guid? ActiveProfileId
    {
        get => _activeProfileId;
        private set => SetProperty(ref _activeProfileId, value);
    }

    public NasDetailsContentState ContentState
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

    public NasDetailsSectionKind SelectedSection
    {
        get => _selectedSection;
        private set => SetProperty(ref _selectedSection, value);
    }

    public bool IsLoading
    {
        get => _isLoading;
        private set
        {
            if (SetProperty(ref _isLoading, value))
            {
                RaisePropertyChanged(nameof(CanRefresh));
            }
        }
    }

    public bool HasRefreshError
    {
        get => _hasRefreshError;
        private set => SetProperty(ref _hasRefreshError, value);
    }

    public bool SectionNoticeIsOpen
    {
        get => _sectionNoticeIsOpen;
        private set => SetProperty(ref _sectionNoticeIsOpen, value);
    }

    public string SectionNoticeTitle
    {
        get => _sectionNoticeTitle;
        private set => SetProperty(ref _sectionNoticeTitle, value);
    }

    public string SectionNoticeMessage
    {
        get => _sectionNoticeMessage;
        private set => SetProperty(ref _sectionNoticeMessage, value);
    }

    public bool HasContent => ContentState == NasDetailsContentState.Content;
    public bool IsEmpty => ContentState == NasDetailsContentState.Empty;
    public bool HasError => ContentState == NasDetailsContentState.Error;
    public bool IsUnavailable => ContentState == NasDetailsContentState.Unavailable;
    public bool CanRefresh => !IsLoading &&
        _repository?.Availability.Status == NasDetailsAvailabilityStatus.Available;

    private NasDetailsProfileState? CurrentProfile => ActiveProfileId is Guid id &&
        _profiles.TryGetValue(id, out var profile) ? profile : null;

    public async Task ActivateAsync(INasDetailsRepository repository)
    {
        ThrowIfDisposed();
        ArgumentNullException.ThrowIfNull(repository);
        SaveCurrentProfileState();
        CancelRequest();
        _repository = repository;
        ActiveProfileId = repository.ProfileId;

        if (repository.Availability.Status != NasDetailsAvailabilityStatus.Available)
        {
            ClearContent();
            HasRefreshError = false;
            ContentState = NasDetailsContentState.Unavailable;
            RaisePropertyChanged(nameof(CanRefresh));
            return;
        }

        if (_profiles.TryGetValue(repository.ProfileId, out var cached) && cached.Loaded)
        {
            TouchProfile(repository.ProfileId);
            RestoreProfile(cached);
            RaisePropertyChanged(nameof(CanRefresh));
            return;
        }

        var profile = cached ?? new NasDetailsProfileState();
        CacheProfile(repository.ProfileId, profile);
        SelectedSection = profile.SelectedSection;
        await LoadAsync(profile, preserveContentOnFailure: false);
    }

    public Task RefreshAsync()
    {
        ThrowIfDisposed();
        return CanRefresh && CurrentProfile is { } profile
            ? LoadAsync(profile, preserveContentOnFailure: profile.Loaded)
            : Task.CompletedTask;
    }

    public void SelectSection(NasDetailsSectionKind section)
    {
        ThrowIfDisposed();
        SelectedSection = section;
        if (CurrentProfile is { } profile)
        {
            profile.SelectedSection = section;
            ApplySection(profile);
        }
    }

    public void Deactivate()
    {
        ThrowIfDisposed();
        SaveCurrentProfileState();
        CancelRequest();
        _repository = null;
        ActiveProfileId = null;
        ClearContent();
        HasRefreshError = false;
        ContentState = NasDetailsContentState.Loading;
        RaisePropertyChanged(nameof(CanRefresh));
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
        CancelRequest();
    }

    private async Task LoadAsync(
        NasDetailsProfileState profile,
        bool preserveContentOnFailure)
    {
        var repository = RequireRepository();
        var request = BeginRequest();
        IsLoading = true;
        HasRefreshError = false;
        if (!preserveContentOnFailure || !profile.Loaded)
        {
            ClearContent();
            ContentState = NasDetailsContentState.Loading;
        }
        try
        {
            var snapshot = await repository.LoadDetailsAsync(request.Cancellation.Token);
            if (!IsCurrent(request.Generation, repository))
            {
                return;
            }
            if (snapshot.ProfileId != repository.ProfileId)
            {
                throw new InvalidDataException("NAS details returned another profile.");
            }
            profile.Snapshot = snapshot;
            profile.Loaded = true;
            ApplySection(profile);
            TouchProfile(repository.ProfileId);
        }
        catch (OperationCanceledException) when (request.Cancellation.IsCancellationRequested)
        {
        }
        catch
        {
            if (IsCurrent(request.Generation, repository))
            {
                HasRefreshError = true;
                if (!preserveContentOnFailure || !profile.Loaded)
                {
                    ClearContent();
                    ContentState = NasDetailsContentState.Error;
                }
            }
        }
        finally
        {
            if (IsCurrent(request.Generation, repository))
            {
                IsLoading = false;
            }
        }
    }

    private void ApplySection(NasDetailsProfileState profile)
    {
        var snapshot = profile.Snapshot;
        if (snapshot is null)
        {
            ClearContent();
            ContentState = NasDetailsContentState.Loading;
            return;
        }
        RebuildSections(snapshot);
        Rows.Clear();
        SectionNoticeIsOpen = false;
        var section = SelectedSection switch
        {
            NasDetailsSectionKind.Packages => ProjectSection(
                snapshot.Packages,
                PackageRow),
            NasDetailsSectionKind.ScheduledTasks => ProjectSection(
                snapshot.ScheduledTasks,
                TaskRow),
            NasDetailsSectionKind.Logs => ProjectSection(
                snapshot.Logs,
                LogRow),
            NasDetailsSectionKind.Connections => ProjectSection(
                snapshot.Connections,
                ConnectionRow),
            _ => throw new ArgumentOutOfRangeException(nameof(SelectedSection)),
        };
        foreach (var row in section.Rows)
        {
            Rows.Add(row);
        }
        if (section.Status == NasDetailsSectionStatus.Failed)
        {
            ContentState = NasDetailsContentState.Error;
            return;
        }
        if (section.Status == NasDetailsSectionStatus.Unavailable)
        {
            ContentState = NasDetailsContentState.Unavailable;
            return;
        }
        if (section.IsTruncated)
        {
            SectionNoticeTitle = L.Get("NasDetailsTruncatedTitle");
            SectionNoticeMessage = L.Get("NasDetailsTruncatedMessage");
            SectionNoticeIsOpen = true;
        }
        ContentState = Rows.Count > 0
            ? NasDetailsContentState.Content
            : NasDetailsContentState.Empty;
    }

    private void RebuildSections(NasDetailsSnapshot snapshot)
    {
        var selected = SelectedSection;
        Sections.Clear();
        Sections.Add(SectionOption(
            NasDetailsSectionKind.Packages,
            snapshot.Packages.Status,
            snapshot.Packages.Items.Count));
        Sections.Add(SectionOption(
            NasDetailsSectionKind.ScheduledTasks,
            snapshot.ScheduledTasks.Status,
            snapshot.ScheduledTasks.Items.Count));
        Sections.Add(SectionOption(
            NasDetailsSectionKind.Logs,
            snapshot.Logs.Status,
            snapshot.Logs.Items.Count));
        Sections.Add(SectionOption(
            NasDetailsSectionKind.Connections,
            snapshot.Connections.Status,
            snapshot.Connections.Items.Count));
        SelectedSection = selected;
    }

    private NasDetailsSectionOption SectionOption(
        NasDetailsSectionKind section,
        NasDetailsSectionStatus status,
        int count)
    {
        var title = SectionTitle(section);
        var statusText = status switch
        {
            NasDetailsSectionStatus.Available => L.Format("NasDetailsSectionCount", count),
            NasDetailsSectionStatus.Unavailable => L.Get("NasDetailsSectionUnavailable"),
            NasDetailsSectionStatus.Failed => L.Get("NasDetailsSectionFailed"),
            _ => L.Get("UnknownValue"),
        };
        return new NasDetailsSectionOption(
            section,
            title,
            statusText,
            L.Format("NasDetailsSectionAutomationName", title, statusText));
    }

    private SectionProjection ProjectSection<T>(
        NasDetailsSection<T> section,
        Func<T, NasDetailsRow> projector) =>
        new(
            section.Status,
            section.Items.Select(projector).ToArray(),
            section.IsTruncated);

    private static NasDetailsRow PackageRow(NasPackageSummary item) =>
        new(
            item.Id,
            item.Name,
            item.Version ?? L.Get("UnknownValue"),
            StatusText(item.State, item.Status),
            "\uE7B8",
            L.Format("NasDetailsRowAutomationName", item.Name, item.Status));

    private static NasDetailsRow TaskRow(NasScheduledTaskSummary item)
    {
        var status = item.IsEnabled switch
        {
            true => L.Get("NasDetailsTaskEnabled"),
            false => L.Get("NasDetailsTaskDisabled"),
            null => L.Get("UnknownValue"),
        };
        return new NasDetailsRow(
            item.Id,
            item.Name,
            item.NextRun ?? L.Get("NasDetailsTaskNoNextRun"),
            status,
            "\uE823",
            L.Format("NasDetailsRowAutomationName", item.Name, status));
    }

    private static NasDetailsRow LogRow(NasLogSummary item)
    {
        var time = item.Time?.ToLocalTime().ToString("g") ?? L.Get("UnknownValue");
        return new NasDetailsRow(
            item.Id,
            item.Source,
            time,
            item.Level,
            "\uE9D9",
            L.Format("NasDetailsRowAutomationName", item.Source, item.Level));
    }

    private static NasDetailsRow ConnectionRow(NasConnectionSummary item)
    {
        var time = item.ConnectedAt?.ToLocalTime().ToString("g") ?? L.Get("UnknownValue");
        var status = item.IsCurrent
            ? L.Get("NasDetailsConnectionCurrent")
            : L.Get("NasDetailsConnectionActive");
        return new NasDetailsRow(
            item.Id,
            item.Protocol,
            $"{item.Type} · {time}",
            status,
            "\uE968",
            L.Format("NasDetailsRowAutomationName", item.Protocol, status));
    }

    private string SectionTitle(NasDetailsSectionKind section) => section switch
    {
        NasDetailsSectionKind.Packages => L.Get("NasDetailsSectionPackages"),
        NasDetailsSectionKind.ScheduledTasks => L.Get("NasDetailsSectionTasks"),
        NasDetailsSectionKind.Logs => L.Get("NasDetailsSectionLogs"),
        NasDetailsSectionKind.Connections => L.Get("NasDetailsSectionConnections"),
        _ => throw new ArgumentOutOfRangeException(nameof(section)),
    };

    private static string StatusText(ResourceState state, string fallback) => state switch
    {
        ResourceState.Running or ResourceState.Healthy => L.Get("StatusNormal"),
        ResourceState.Stopped => L.Get("StatusStopped"),
        ResourceState.Paused => L.Get("StatusPaused"),
        ResourceState.Waiting => L.Get("StatusWaiting"),
        ResourceState.Warning => L.Get("StatusWarning"),
        ResourceState.Error => L.Get("StatusError"),
        _ => string.IsNullOrWhiteSpace(fallback) ? L.Get("UnknownValue") : fallback,
    };

    private void RestoreProfile(NasDetailsProfileState profile)
    {
        HasRefreshError = false;
        SelectedSection = profile.SelectedSection;
        ApplySection(profile);
    }

    private void SaveCurrentProfileState()
    {
        if (ActiveProfileId is Guid profileId &&
            _profiles.TryGetValue(profileId, out var profile))
        {
            profile.SelectedSection = SelectedSection;
        }
    }

    private void CacheProfile(Guid profileId, NasDetailsProfileState profile)
    {
        _profiles[profileId] = profile;
        TouchProfile(profileId);
        while (_profileOrder.Count > MaximumCachedProfiles)
        {
            var last = _profileOrder.Last?.Value;
            if (last is Guid removed)
            {
                _profiles.Remove(removed);
                _profileOrder.RemoveLast();
            }
        }
    }

    private void TouchProfile(Guid profileId)
    {
        var node = _profileOrder.Find(profileId);
        if (node is not null)
        {
            _profileOrder.Remove(node);
        }
        _profileOrder.AddFirst(profileId);
    }

    private void ClearContent()
    {
        Sections.Clear();
        Rows.Clear();
        SectionNoticeIsOpen = false;
    }

    private RequestState BeginRequest()
    {
        CancelRequest();
        var cancellation = new CancellationTokenSource();
        _requestCancellation = cancellation;
        return new RequestState(++_generation, cancellation);
    }

    private void CancelRequest()
    {
        _generation++;
        var cancellation = _requestCancellation;
        _requestCancellation = null;
        cancellation?.Cancel();
        cancellation?.Dispose();
    }

    private bool IsCurrent(long generation, INasDetailsRepository repository) =>
        !_disposed &&
        generation == _generation &&
        ReferenceEquals(repository, _repository) &&
        ActiveProfileId == repository.ProfileId;

    private INasDetailsRepository RequireRepository() =>
        _repository ?? throw new InvalidOperationException("NAS details are inactive.");

    private void RaiseStateProperties()
    {
        RaisePropertyChanged(nameof(HasContent));
        RaisePropertyChanged(nameof(IsEmpty));
        RaisePropertyChanged(nameof(HasError));
        RaisePropertyChanged(nameof(IsUnavailable));
    }

    private void ThrowIfDisposed() =>
        ObjectDisposedException.ThrowIf(_disposed, this);

    private static LocalizationService L => LocalizationService.Current;

    private sealed record RequestState(
        long Generation,
        CancellationTokenSource Cancellation);

    private sealed record SectionProjection(
        NasDetailsSectionStatus Status,
        IReadOnlyList<NasDetailsRow> Rows,
        bool IsTruncated);
}
