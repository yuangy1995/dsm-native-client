using LanStash.Domain;

namespace LanStash.App.Features.Files.Office;

internal enum OfficeEditingPhase { Preparing, Watching, WaitingForSave, Saving, Saved, Paused, Conflict, ResultUnavailable, Stopped }

internal sealed class OfficeEditingSession(IOfficeEditingRepository repository, FileItem item, string localPath)
{
    public Guid Id { get; init; } = Guid.NewGuid();
    public IOfficeEditingRepository Repository { get; set; } = repository;
    public FileItem Item { get; } = item;
    public string LocalPath { get; } = localPath;
    public OfficeEditingSessionInfo? Info { get; set; }
    public OfficeEditingPhase Phase { get; set; } = OfficeEditingPhase.Preparing;
    public bool Busy { get; set; }
    public bool Watching { get; set; }
    public bool Connected { get; set; } = true;
    public bool LocalUnavailable { get; set; }
    public bool StorageUnavailable { get; set; }
    public IOfficeLocalCopy? Copy { get; set; }
    public OfficeLocalStamp? SynchronizedStamp { get; set; }
    public OfficeLocalStamp? ObservedStamp { get; set; }
    public DateTimeOffset? ObservedAt { get; set; }
    public DateTimeOffset? UnavailableSince { get; set; }
    public CancellationTokenSource Lifetime { get; set; } = new();
    public SemaphoreSlim Gate { get; } = new(1, 1);
    public bool CanResume => Connected && !Busy && !Watching && !StorageUnavailable &&
        Repository.OfficeAvailability.CanAutoSave && Info is { StopRequested: false } &&
        Phase is OfficeEditingPhase.Paused or OfficeEditingPhase.Saved;
    public bool CanReview => Connected && !Busy && !StorageUnavailable && Phase == OfficeEditingPhase.ResultUnavailable;
    public override string ToString() => nameof(OfficeEditingSession);
}

/// <summary>由应用持有，预览页面关闭只释放预览，不结束本机编辑。</summary>
internal sealed class OfficeEditingCoordinator : IDisposable
{
    private readonly IOfficeLocalFiles _files;
    private readonly Func<Guid, string, string, CancellationToken, Task> _validateLocation;
    private readonly List<OfficeEditingSession> _sessions = [];
    private readonly CancellationTokenSource _lifetime = new();
    private Task? _monitor;
    private bool _disposed;

    public OfficeEditingCoordinator(Func<Guid, string, string, CancellationToken, Task> validateLocation)
        : this(new OfficeLocalFiles(), validateLocation) { }
    internal OfficeEditingCoordinator(IOfficeLocalFiles files, Func<Guid, string, string, CancellationToken, Task> validateLocation)
    { _files = files; _validateLocation = validateLocation; }
    public event EventHandler? Changed;
    public IReadOnlyList<OfficeEditingSession> Sessions { get { lock (_sessions) return _sessions.ToArray(); } }
    public bool HasBusySessions => Sessions.Any(session => session.Busy);
    public bool HasActiveSessions => Sessions.Any(session => session.Info?.State != OfficeEditingState.Stopped);
    public OfficeEditingSession? SessionFor(IOfficeEditingRepository repository, string path, bool includeStopped = false)
    {
        var matches = Sessions.Where(session => session.Repository.ProfileId == repository.ProfileId &&
            session.Repository.OfficeOwnerId == repository.OfficeOwnerId && session.Item.Path == path).ToArray();
        return matches.FirstOrDefault(session => session.Info?.State != OfficeEditingState.Stopped) ??
            (includeStopped ? matches.LastOrDefault() : null);
    }
    public bool TryPrepareExit()
    {
        if (HasBusySessions) return false;
        foreach (var session in Sessions) session.Watching = false;
        return true;
    }

    public async Task AttachAsync(IOfficeEditingRepository repository, CancellationToken token = default)
    {
        var records = await repository.GetOfficeSessionsAsync(token).ConfigureAwait(true);
        token.ThrowIfCancellationRequested();
        foreach (var info in records)
        {
            var existing = Sessions.SingleOrDefault(session => session.Id == info.Id && session.Repository.OfficeOwnerId == info.OwnerId);
            if (existing is { Busy: true }) continue;
            if (existing is not null)
            {
                existing.Repository = repository; existing.Connected = true;
                if (existing.Lifetime.IsCancellationRequested) { existing.Lifetime.Dispose(); existing.Lifetime = new(); }
                existing.Info = info;
                if (!existing.Watching)
                {
                    SetFromInfo(existing);
                    if (existing.Phase == OfficeEditingPhase.Watching) existing.Phase = OfficeEditingPhase.Paused;
                }
            }
            else
            {
                var session = new OfficeEditingSession(repository, info.Baseline.Metadata.Item, info.LocalPath) { Id = info.Id, Info = info };
                SetFromInfo(session);
                // 冷启动始终要求用户继续；只读核查完成也不会自动打开编辑器或重新上传。
                if (session.Phase is OfficeEditingPhase.Saved or OfficeEditingPhase.Watching) session.Phase = OfficeEditingPhase.Paused;
                lock (_sessions) _sessions.Add(session);
            }
        }
        Notify();
    }

    public async Task<OfficeEditingSession> BeginAsync(IOfficeEditingRepository repository, FileItem item, string localPath,
        CancellationToken token = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (!OfficeDocumentFormat.Supports(item) || !repository.OfficeAvailability.CanAutoSave) throw new NotSupportedException("office.edit-unavailable");
        localPath = Path.GetFullPath(localPath);
        var session = new OfficeEditingSession(repository, item, localPath) { Busy = true };
        lock (_sessions)
        {
            if (_sessions.Any(other => other.Info?.State != OfficeEditingState.Stopped &&
                (other.Repository.ProfileId == repository.ProfileId && other.Item.Path == item.Path ||
                 string.Equals(other.LocalPath, localPath, StringComparison.OrdinalIgnoreCase)))) throw new InvalidOperationException("office.already-editing");
            _sessions.Add(session);
        }
        Notify();
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(token, session.Lifetime.Token);
        try
        {
            await _validateLocation(repository.ProfileId, item.Path, localPath, linked.Token).ConfigureAwait(true);
            var baseline = await repository.ReadOfficeRemoteAsync(item.Path, linked.Token).ConfigureAwait(true);
            var fingerprint = await _files.DownloadAsync(repository, baseline, localPath, linked.Token).ConfigureAwait(true);
            linked.Token.ThrowIfCancellationRequested();
            await _validateLocation(repository.ProfileId, item.Path, localPath, linked.Token).ConfigureAwait(true);
            session.Info = await repository.CreateOfficeSessionAsync(session.Id, localPath, baseline, fingerprint, linked.Token).ConfigureAwait(true);
            linked.Token.ThrowIfCancellationRequested();
            session.Copy = _files.Open(localPath);
            // 准备期间编辑器可能已保存；第一次监测也要比较正文，不能把当前时间戳直接当作已同步。
            session.SynchronizedStamp = null;
            session.Phase = OfficeEditingPhase.Watching; session.Watching = true;
            return session;
        }
        catch
        {
            session.Watching = false; session.Phase = OfficeEditingPhase.Paused;
            if (session.Info is null) { lock (_sessions) _sessions.Remove(session); session.Lifetime.Dispose(); }
            throw;
        }
        finally { session.Busy = false; Notify(); }
    }

    public void StartMonitoring() => _monitor ??= MonitorAsync();
    private async Task MonitorAsync()
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(1));
        try
        {
            while (await timer.WaitForNextTickAsync(_lifetime.Token).ConfigureAwait(true))
                foreach (var session in Sessions)
                    await PollAsync(session, DateTimeOffset.UtcNow).ConfigureAwait(true);
        }
        catch (OperationCanceledException) when (_lifetime.IsCancellationRequested) { }
    }

    internal async Task PollAsync(OfficeEditingSession session, DateTimeOffset now)
    {
        if (_disposed || !session.Watching || !session.Connected || session.Busy || session.Info is null ||
            !await session.Gate.WaitAsync(0).ConfigureAwait(true)) return;
        session.Busy = true;
        var readingLocalCopy = true;
        try
        {
            session.Copy ??= _files.Open(session.LocalPath);
            var stamp = session.Copy.ReadStamp();
            session.UnavailableSince = null; session.LocalUnavailable = false;
            if (stamp == session.SynchronizedStamp)
            { session.ObservedStamp = null; session.ObservedAt = null; return; }
            if (stamp != session.ObservedStamp)
            {
                session.ObservedStamp = stamp; session.ObservedAt = now; session.Phase = OfficeEditingPhase.WaitingForSave;
                return;
            }
            if (session.ObservedAt is null || now - session.ObservedAt < TimeSpan.FromSeconds(2)) return;
            await using var snapshot = await session.Copy.FreezeAsync(session.Lifetime.Token).ConfigureAwait(true);
            readingLocalCopy = false;
            if (string.Equals(snapshot.Fingerprint.Sha256, session.Info.Fingerprint.Sha256, StringComparison.OrdinalIgnoreCase))
            {
                session.SynchronizedStamp = snapshot.Stamp; session.ObservedStamp = null; session.ObservedAt = null;
                session.Phase = OfficeEditingPhase.Watching; return;
            }
            await _validateLocation(session.Repository.ProfileId, session.Item.Path, session.LocalPath, session.Lifetime.Token).ConfigureAwait(true);
            session.Lifetime.Token.ThrowIfCancellationRequested();
            session.Phase = OfficeEditingPhase.Saving; Notify();
            session.Info = await session.Repository.SaveOfficeSessionAsync(session.Id, snapshot.Content,
                snapshot.Fingerprint, session.Lifetime.Token).ConfigureAwait(true);
            SetFromInfo(session);
            if (session.Info.State == OfficeEditingState.Saved)
            {
                session.SynchronizedStamp = snapshot.Stamp; session.ObservedStamp = null; session.ObservedAt = null;
            }
            session.Watching = session.Connected && !session.Lifetime.IsCancellationRequested &&
                session.Info.State is OfficeEditingState.Ready or OfficeEditingState.Saved;
        }
        catch (OperationCanceledException)
        { session.Watching = false; if (session.Phase != OfficeEditingPhase.ResultUnavailable) session.Phase = OfficeEditingPhase.Paused; }
        catch (IOException) when (readingLocalCopy && session.Repository.OfficeAvailability.RecoveryAvailable)
        {
            // 编辑器锁定或原子替换期间允许短暂不可读；长期不可读才暂停，始终保留副本。
            session.ObservedStamp = null; session.ObservedAt = null; session.UnavailableSince ??= now;
            session.Phase = OfficeEditingPhase.WaitingForSave;
            if (now - session.UnavailableSince >= TimeSpan.FromSeconds(30))
            { session.Watching = false; session.LocalUnavailable = true; session.Phase = OfficeEditingPhase.Paused; }
        }
        catch
        {
            session.Watching = false; session.StorageUnavailable = !session.Repository.OfficeAvailability.RecoveryAvailable;
            session.Phase = session.Phase == OfficeEditingPhase.Saving ? OfficeEditingPhase.ResultUnavailable : OfficeEditingPhase.Paused;
        }
        finally
        {
            if (!session.Connected || _disposed) { session.Copy?.Dispose(); session.Copy = null; }
            session.Busy = false; session.Gate.Release(); Notify();
        }
    }

    public async Task ResumeAsync(OfficeEditingSession session)
    {
        if (!session.CanResume || !await session.Gate.WaitAsync(0).ConfigureAwait(true)) return;
        session.Busy = true; Notify();
        var localReady = false;
        try
        {
            await _validateLocation(session.Repository.ProfileId, session.Item.Path, session.LocalPath, session.Lifetime.Token).ConfigureAwait(true);
            session.Copy ??= _files.Open(session.LocalPath);
            _ = session.Copy.ReadStamp();
            localReady = true;
            session.Info = await session.Repository.ResumeOfficeSessionAsync(session.Id, session.Lifetime.Token).ConfigureAwait(true);
            SetFromInfo(session);
            session.Watching = session.Info.State == OfficeEditingState.Ready;
            session.ObservedStamp = null; session.ObservedAt = null; session.LocalUnavailable = false;
        }
        catch
        { session.Phase = OfficeEditingPhase.Paused; session.LocalUnavailable = !localReady; session.StorageUnavailable = !session.Repository.OfficeAvailability.RecoveryAvailable; }
        finally { session.Busy = false; session.Gate.Release(); Notify(); }
    }

    public async Task ReviewAsync(OfficeEditingSession session)
    {
        if (!session.CanReview || !await session.Gate.WaitAsync(0).ConfigureAwait(true)) return;
        session.Busy = true; Notify();
        try
        {
            session.Info = await session.Repository.ReviewOfficeSessionAsync(session.Id, session.Lifetime.Token).ConfigureAwait(true);
            SetFromInfo(session);
        }
        catch { session.StorageUnavailable = !session.Repository.OfficeAvailability.RecoveryAvailable; }
        finally { session.Busy = false; session.Gate.Release(); Notify(); }
    }

    public async Task StopAsync(OfficeEditingSession session)
    {
        session.Watching = false;
        if (session.Info is null) { session.Lifetime.Cancel(); return; }
        session.Info = await session.Repository.StopOfficeSessionAsync(session.Id).ConfigureAwait(true);
        SetFromInfo(session); session.Copy?.Dispose(); session.Copy = null; Notify();
    }

    public async Task ExportAsync(OfficeEditingSession session, string destination, CancellationToken token = default)
    {
        destination = Path.GetFullPath(destination);
        if (Sessions.Any(other => string.Equals(other.LocalPath, destination, StringComparison.OrdinalIgnoreCase)))
            throw new IOException("office.copy-in-use");
        // 导出只校验本机位置，不受原远端冲突或离线状态限制。
        await _validateLocation(Guid.Empty, string.Empty, destination, token).ConfigureAwait(true);
        using var copy = _files.Open(session.LocalPath);
        await _files.ExportAsync(copy, destination, token).ConfigureAwait(true);
    }

    public void Disconnect(Guid profileId)
    {
        foreach (var session in Sessions.Where(session => session.Repository.ProfileId == profileId))
        {
            session.Watching = false; session.Connected = false; session.Lifetime.Cancel();
            if (!session.Busy)
            {
                session.Copy?.Dispose(); session.Copy = null;
                if (session.Phase is OfficeEditingPhase.Watching or OfficeEditingPhase.WaitingForSave or OfficeEditingPhase.Saved)
                    session.Phase = OfficeEditingPhase.Paused;
            }
        }
        Notify();
    }

    private static void SetFromInfo(OfficeEditingSession session) => session.Phase = session.Info?.State switch
    {
        OfficeEditingState.Ready => OfficeEditingPhase.Watching,
        OfficeEditingState.Saved => OfficeEditingPhase.Saved,
        OfficeEditingState.Conflict => OfficeEditingPhase.Conflict,
        OfficeEditingState.ResultUnavailable => OfficeEditingPhase.ResultUnavailable,
        OfficeEditingState.Stopped => OfficeEditingPhase.Stopped,
        _ => OfficeEditingPhase.Paused,
    };
    private void Notify() => Changed?.Invoke(this, EventArgs.Empty);
    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true; _lifetime.Cancel();
        foreach (var session in Sessions)
        { session.Watching = false; session.Lifetime.Cancel(); if (!session.Busy) { session.Copy?.Dispose(); session.Copy = null; } }
    }
}
