using System.Collections.ObjectModel;
using System.Globalization;
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
    private NasDetailsSectionKind _selectedSection = NasDetailsSectionKind.SystemOverview;
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
        private set
        {
            if (SetProperty(ref _selectedSection, value))
            {
                RaisePropertyChanged(nameof(EmptyTitle));
                RaisePropertyChanged(nameof(EmptyMessage));
            }
        }
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
    public string EmptyTitle => SelectedSection == NasDetailsSectionKind.ShareAccess
        ? L.Get("NasDetailsShareAccessEmptyTitle")
        : L.Get("NasDetailsEmptyTitleText");
    public string EmptyMessage => SelectedSection == NasDetailsSectionKind.ShareAccess
        ? L.Get("NasDetailsShareAccessEmptyMessage")
        : L.Get("NasDetailsEmptyMessageText");
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
            NasDetailsSectionKind.SystemOverview => ProjectSystemSection(snapshot.SystemOverview),
            NasDetailsSectionKind.StorageHealth => ProjectSection(
                snapshot.StorageHealth,
                StorageRow),
            NasDetailsSectionKind.SystemUpdate => ProjectUpdateSection(snapshot.SystemUpdate),
            NasDetailsSectionKind.ShareAccess => ProjectShareAccessSection(snapshot.ShareAccess),
            NasDetailsSectionKind.SystemActivity => ProjectSystemActivitySection(snapshot.SystemActivity),
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
            NasDetailsSectionKind.SystemOverview,
            snapshot.SystemOverview.Status,
            snapshot.SystemOverview.Items.SelectMany(SystemRows).Count()));
        Sections.Add(SectionOption(
            NasDetailsSectionKind.StorageHealth,
            snapshot.StorageHealth.Status,
            snapshot.StorageHealth.Items.Count));
        Sections.Add(SectionOption(
            NasDetailsSectionKind.SystemUpdate,
            snapshot.SystemUpdate.Status,
            snapshot.SystemUpdate.Items.SelectMany(UpdateRows).Count()));
        Sections.Add(SectionOption(
            NasDetailsSectionKind.ShareAccess,
            snapshot.ShareAccess.Status,
            snapshot.ShareAccess.Items.Count));
        Sections.Add(SectionOption(
            NasDetailsSectionKind.SystemActivity,
            snapshot.SystemActivity.Status,
            snapshot.SystemActivity.Items.Sum(item => item.Processes.Count)));
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

    private static SectionProjection ProjectSystemSection(
        NasDetailsSection<NasSystemHealthSummary> section) =>
        new(
            section.Status,
            section.Items.SelectMany(SystemRows).ToArray(),
            section.IsTruncated);

    private static SectionProjection ProjectUpdateSection(
        NasDetailsSection<NasSystemUpdateSummary> section) =>
        new(
            section.Status,
            section.Items.SelectMany(UpdateRows).ToArray(),
            section.IsTruncated);

    private static IEnumerable<NasDetailsRow> UpdateRows(NasSystemUpdateSummary item)
    {
        var title = item.IsUpdateAvailable
            ? L.Get("NasDetailsUpdateAvailable")
            : item.CurrentVersion is not null
                ? L.Get("NasDetailsUpdateCurrent")
                : L.Get("NasDetailsUpdateStatusUnavailable");
        var currentVersion = item.CurrentVersion is { } current
            ? L.Format("NasDetailsUpdateCurrentVersion", current)
            : L.Get("NasDetailsUpdateCurrentVersionUnavailable");
        var latestVersion = item.IsUpdateAvailable && item.LatestVersion is { } latest
            ? L.Format("NasDetailsUpdateLatestVersion", latest)
            : L.Get("NasDetailsUpdateNoNewerVersion");
        yield return Row(
            "system-update",
            title,
            currentVersion,
            latestVersion,
            item.IsUpdateAvailable ? "\uE895" : "\uE73E");
        if (item.ReleaseNotes is { } releaseNotes)
        {
            yield return Row(
                "system-update-notes",
                L.Get("NasDetailsUpdateReleaseNotes"),
                releaseNotes,
                string.Empty,
                "\uE8A5");
        }
    }

    private static SectionProjection ProjectShareAccessSection(
        NasDetailsSection<NasShareAccessSummary> section)
    {
        if (section.Status != NasDetailsSectionStatus.Available || section.Items.Count == 0)
        {
            return new(section.Status, [], section.IsTruncated);
        }
        var rows = new List<NasDetailsRow>
        {
            Row(
                "share-access-scope",
                L.Get("NasDetailsShareAccessScopeTitle"),
                L.Get("NasDetailsShareAccessScopeMessage"),
                string.Empty,
                "\uE77B"),
        };
        rows.AddRange(section.Items.Select(ShareAccessRow));
        return new(section.Status, rows, section.IsTruncated);
    }

    private static NasDetailsRow ShareAccessRow(NasShareAccessSummary item)
    {
        var access = item.AccessLevel switch
        {
            NasShareAccessLevel.ReadWrite => L.Get("NasDetailsShareAccessReadWrite"),
            NasShareAccessLevel.ReadOnly => L.Get("NasDetailsShareAccessReadOnly"),
            NasShareAccessLevel.Unknown => L.Get("NasDetailsShareAccessUnknown"),
            _ => throw new ArgumentOutOfRangeException(nameof(item.AccessLevel)),
        };
        var delete = item.CanDelete
            ? L.Get("NasDetailsShareAccessCanDelete")
            : string.Empty;
        return Row(
            item.Id,
            item.Name,
            access,
            delete,
            item.AccessLevel switch
            {
                NasShareAccessLevel.ReadWrite => "\uE70F",
                NasShareAccessLevel.ReadOnly => "\uE890",
                _ => "\uE897",
            });
    }

    private static SectionProjection ProjectSystemActivitySection(
        NasDetailsSection<NasSystemActivitySummary> section)
    {
        if (section.Status != NasDetailsSectionStatus.Available || section.Items.Count == 0 ||
            section.Items[0].Processes.Count == 0)
        {
            return new(section.Status, [], section.IsTruncated);
        }
        var activity = section.Items[0];
        var groups = activity.Groups.ToDictionary(group => group.Id, StringComparer.Ordinal);
        var rows = new List<NasDetailsRow>
        {
            Row(
                "system-activity-scope",
                L.Get("NasDetailsSystemActivityScopeTitle"),
                L.Get("NasDetailsSystemActivityScopeMessage"),
                activity.AreGroupsUnavailable
                    ? L.Get("NasDetailsSystemActivityGroupsUnavailable")
                    : string.Empty,
                "\uE946"),
        };
        rows.AddRange(activity.Processes.Select(item =>
        {
            var groupName = item.GroupId is { } groupId && groups.TryGetValue(groupId, out var group)
                ? group.Name
                : L.Get("NasDetailsSystemActivityGroupUnavailable");
            return Row(
                item.Id,
                item.Name,
                L.Format("NasDetailsSystemActivityProcessId", item.ProcessId),
                item.Status is { } status
                    ? L.Format("NasDetailsSystemActivityStatusAndGroup", status, groupName)
                    : L.Format("NasDetailsSystemActivityGroup", groupName),
                "\uE9D9");
        }));
        return new(section.Status, rows, section.IsTruncated);
    }

    private static IEnumerable<NasDetailsRow> SystemRows(NasSystemHealthSummary item)
    {
        if (item.Model is not null || item.Version is not null)
        {
            yield return Row(
                "system-device",
                L.Get("NasDetailsSystemDevice"),
                item.Model ?? L.Get("UnknownValue"),
                item.Version is { } version
                    ? L.Format("NasDetailsSystemVersionValue", version)
                    : L.Get("UnknownValue"),
                "\uE770");
        }
        if (item.UptimeSeconds is long uptime)
        {
            var value = FormatDuration(uptime);
            yield return Row(
                "system-uptime",
                L.Get("NasDetailsSystemUptime"),
                value,
                string.Empty,
                "\uE823");
        }
        if (item.CpuModel is not null || item.CpuCoreCount is not null || item.CpuClockMhz is not null)
        {
            var detail = item.CpuModel ?? L.Get("UnknownValue");
            var status = FormatProcessor(item.CpuCoreCount, item.CpuClockMhz);
            yield return Row(
                "system-processor",
                L.Get("NasDetailsSystemProcessor"),
                detail,
                status,
                "\uE950");
        }
        if (item.MemoryBytes is long memory)
        {
            var value = FormatBytes(memory);
            yield return Row(
                "system-memory",
                L.Get("NasDetailsSystemMemory"),
                value,
                string.Empty,
                "\uE964");
        }
        if (item.TemperatureCelsius is double temperature)
        {
            var detail = L.Format(
                "NasDetailsTemperatureValue",
                temperature.ToString("0.#", CultureInfo.CurrentCulture));
            var status = item.HasTemperatureWarning
                ? L.Get("NasDetailsTemperatureWarning")
                : L.Get("StatusNormal");
            yield return Row(
                "system-temperature",
                L.Get("NasDetailsSystemTemperature"),
                detail,
                status,
                "\uE7E7");
        }
    }

    private static NasDetailsRow StorageRow(NasStorageHealthSummary item)
    {
        var title = L.Format(item.Kind switch
        {
            NasStorageItemKind.Pool => "NasDetailsStoragePoolName",
            NasStorageItemKind.Volume => "NasDetailsStorageVolumeName",
            NasStorageItemKind.Drive => "NasDetailsStorageDriveName",
            _ => throw new ArgumentOutOfRangeException(nameof(item.Kind)),
        }, item.Ordinal);
        var capacity = item.UsedBytes is long used && item.TotalBytes is long total
            ? L.Format("NasDetailsStorageUsage", FormatBytes(used), FormatBytes(total))
            : item.TotalBytes is long capacityBytes
                ? L.Format("NasDetailsStorageCapacity", FormatBytes(capacityBytes))
                : L.Get("NasDetailsStorageCapacityUnavailable");
        var characteristic = item.Kind switch
        {
            NasStorageItemKind.Pool => item.RaidType,
            NasStorageItemKind.Volume => JoinDetails(
                item.FileSystem,
                item.IsEncrypted ? L.Get("NasDetailsStorageEncrypted") : null),
            NasStorageItemKind.Drive => item.IsSsd ? L.Get("NasDetailsStorageSsd") : null,
            _ => null,
        };
        string? status = item.State == ResourceState.Unknown
            ? null
            : StatusText(item.State, string.Empty);
        if (item.Kind == NasStorageItemKind.Drive)
        {
            status = JoinDetails(
                status,
                StorageHealthText(item.SmartStatus),
                item.TemperatureCelsius is double temperature
                    ? L.Format(
                        "NasDetailsTemperatureValue",
                        temperature.ToString("0.#", CultureInfo.CurrentCulture))
                    : null);
        }
        return Row(
            item.Id,
            title,
            JoinDetails(capacity, characteristic) ?? capacity,
            status ?? L.Get("UnknownValue"),
            item.Kind switch
            {
                NasStorageItemKind.Pool => "\uEDA2",
                NasStorageItemKind.Volume => "\uE7F1",
                _ => "\uEDA2",
            });
    }

    private static NasDetailsRow Row(
        string id,
        string title,
        string detail,
        string status,
        string glyph) =>
        new(
            id,
            title,
            detail,
            status,
            glyph,
            L.Format("NasDetailsRowAutomationName", title, JoinDetails(detail, status) ?? detail));

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
        NasDetailsSectionKind.SystemOverview => L.Get("NasDetailsSectionSystem"),
        NasDetailsSectionKind.StorageHealth => L.Get("NasDetailsSectionStorage"),
        NasDetailsSectionKind.SystemUpdate => L.Get("NasDetailsSectionUpdate"),
        NasDetailsSectionKind.ShareAccess => L.Get("NasDetailsSectionShareAccess"),
        NasDetailsSectionKind.SystemActivity => L.Get("NasDetailsSectionSystemActivity"),
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

    private static string? StorageHealthText(string? value)
    {
        var normalized = value?.Trim().ToLowerInvariant();
        return normalized switch
        {
            "normal" or "healthy" or "good" => L.Get("NasDetailsStorageSmartNormal"),
            "warning" or "warn" => L.Get("NasDetailsStorageSmartWarning"),
            "error" or "failed" or "failing" => L.Get("NasDetailsStorageSmartError"),
            _ => null,
        };
    }

    private static string FormatProcessor(int? cores, int? clockMhz) =>
        (cores, clockMhz) switch
        {
            (int coreCount, int clock) => L.Format("NasDetailsProcessorCoresClock", coreCount, clock),
            (int coreCount, null) => L.Format("NasDetailsProcessorCores", coreCount),
            (null, int clock) => L.Format("NasDetailsProcessorClock", clock),
            _ => L.Get("UnknownValue"),
        };

    private static string FormatDuration(long totalSeconds)
    {
        var safeSeconds = Math.Max(0, totalSeconds);
        var totalHours = safeSeconds / 3600;
        var minutes = (safeSeconds / 60) % 60;
        return totalHours >= 24
            ? L.Format("NasDetailsDurationDaysHours", totalHours / 24, totalHours % 24)
            : L.Format("NasDetailsDurationHoursMinutes", totalHours, minutes);
    }

    private static string FormatBytes(long bytes)
    {
        string[] unitKeys =
        [
            "NasDetailsByteUnitB",
            "NasDetailsByteUnitKB",
            "NasDetailsByteUnitMB",
            "NasDetailsByteUnitGB",
            "NasDetailsByteUnitTB",
        ];
        var scaled = (double)Math.Max(0, bytes);
        var unit = 0;
        while (scaled >= 1024 && unit < unitKeys.Length - 1)
        {
            scaled /= 1024;
            unit++;
        }
        var format = unit == 0 ? "N0" : scaled >= 10 ? "N1" : "N2";
        return L.Format(
            "NasDetailsByteValue",
            scaled.ToString(format, CultureInfo.CurrentCulture),
            L.Get(unitKeys[unit]));
    }

    private static string? JoinDetails(params string?[] values)
    {
        var safe = values.Where(value => !string.IsNullOrWhiteSpace(value)).ToArray();
        return safe.Length switch
        {
            0 => null,
            1 => safe[0],
            _ => string.Join(L.Get("NasDetailsValueSeparator"), safe),
        };
    }

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
