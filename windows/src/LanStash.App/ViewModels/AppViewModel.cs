using System.Collections.ObjectModel;
using System.Text.Json;
using LanStash.App.CloudDrive;
using LanStash.App.Localization;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.App.ViewModels;

public sealed class AppViewModel : ObservableObject
{
    private readonly HttpClient _http = new(new HttpClientHandler
    {
        AllowAutoRedirect = false,
    })
    {
        Timeout = TimeSpan.FromSeconds(45),
    };
    private readonly ISecureSessionStore _sessionStore = new CredentialSessionStore();
    private readonly ISecurePasswordStore _passwordStore = new CredentialPasswordStore();
    private readonly IDsmApiClient _api;
    private readonly DsmConnectionResolver _connectionResolver;
    private readonly DesktopCloudDriveService _cloudDrives = new();
    private readonly string _profilesPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "LanStash",
        "profiles.json");
    private bool _isBusy;
    private string? _errorMessage;
    private string? _connectionStatus;
    private string _displayName = LocalizationService.Current.Get("DefaultNasName");
    private string _host = string.Empty;
    private string _port = string.Empty;
    private string _username = string.Empty;
    private string _password = string.Empty;
    private string _otp = string.Empty;
    private bool _rememberPassword;
    private bool _autoLogin;
    private bool _isInitialized;
    private readonly ConnectionAttemptGate _connectionAttempts = new();
    private readonly Dictionary<Guid, CancellationTokenSource> _desktopDriveTasks = [];
    private readonly Dictionary<Guid, DesktopDriveOfflineProgress> _desktopDriveProgress = [];
    private readonly Dictionary<Guid, DesktopDrivePlanningProgress> _desktopDrivePlanning = [];
    private CancellationTokenSource? _desktopDriveRecoveryCancellation;
    private Task? _desktopDriveRecoveryTask;

    public AppViewModel()
    {
        _api = new DsmApiClient(_http);
        _connectionResolver = new DsmConnectionResolver(
            _api,
            new DsmQuickConnectResolver(_http));
    }

    public event EventHandler<bool>? ConnectionChanged;
    public event EventHandler<string>? PasswordLoaded;
    public event EventHandler? DesktopDriveProgressChanged;

    public ObservableCollection<NasProfile> Profiles { get; } = [];
    public ObservableCollection<AppModule> AvailableModules { get; } = [];
    public ObservableCollection<DesktopDriveMapping> DesktopDriveMappings { get; } = [];

    public NasProfile? ActiveProfile { get; private set; }
    private NasProfile? ActiveConnectionProfile { get; set; }
    public DsmSession? Session { get; private set; }
    public IDsmRepository? Repository { get; private set; }

    public string DisplayName
    {
        get => _displayName;
        set => SetProperty(ref _displayName, value);
    }

    public string Host
    {
        get => _host;
        set => SetProperty(ref _host, value);
    }

    public string Port
    {
        get => _port;
        set => SetProperty(ref _port, value);
    }

    public string Username
    {
        get => _username;
        set => SetProperty(ref _username, value);
    }

    public string Password
    {
        get => _password;
        set => SetProperty(ref _password, value);
    }

    public string Otp
    {
        get => _otp;
        set => SetProperty(ref _otp, value);
    }

    public bool RememberPassword
    {
        get => _rememberPassword;
        set
        {
            if (SetProperty(ref _rememberPassword, value) && !value)
            {
                AutoLogin = false;
            }
        }
    }

    public bool AutoLogin
    {
        get => _autoLogin;
        set
        {
            if (SetProperty(ref _autoLogin, value) && value)
            {
                RememberPassword = true;
            }
        }
    }

    public bool IsBusy
    {
        get => _isBusy;
        private set => SetProperty(ref _isBusy, value);
    }

    public string? ErrorMessage
    {
        get => _errorMessage;
        private set => SetProperty(ref _errorMessage, value);
    }

    public string? ConnectionStatus
    {
        get => _connectionStatus;
        private set => SetProperty(ref _connectionStatus, value);
    }

    public async Task InitializeAsync()
    {
        if (_isInitialized)
        {
            return;
        }
        _isInitialized = true;
        try
        {
            await _cloudDrives.InitializeAsync().ConfigureAwait(true);
        }
        catch
        {
            // 云盘配置异常不能阻止主应用加载已有 NAS 配置。
        }
        RefreshDesktopDriveMappings();
        await LoadProfilesAsync().ConfigureAwait(true);
        var profile = Profiles.LastOrDefault();
        if (profile is null)
        {
            return;
        }
        await SelectProfileAsync(profile).ConfigureAwait(true);
        if (profile.AutoLogin && !string.IsNullOrEmpty(Password))
        {
            await RestoreAsync(profile, fallbackToPassword: true).ConfigureAwait(true);
        }
    }

    public async Task SelectProfileAsync(NasProfile profile)
    {
        var storedPassword = await _passwordStore.LoadAsync(profile.Id).ConfigureAwait(true)
            ?? string.Empty;
        ApplySelectedProfile(profile, storedPassword);
    }

    public void NewProfile()
    {
        DisplayName = LocalizationService.Current.Get("DefaultNasName");
        Host = string.Empty;
        Port = string.Empty;
        Username = string.Empty;
        Password = string.Empty;
        RememberPassword = false;
        AutoLogin = false;
        PasswordLoaded?.Invoke(this, string.Empty);
        Otp = string.Empty;
        ErrorMessage = null;
        ConnectionStatus = null;
    }

    public async Task ConnectAsync()
    {
        if (IsBusy)
        {
            return;
        }
        IsBusy = true;
        ErrorMessage = null;
        var localization = LocalizationService.Current;
        ConnectionStatus = localization.Get("StatusCheckingNas");
        var attempt = _connectionAttempts.Begin();
        var cancellation = attempt.Cancellation;
        try
        {
            var profile = new NasProfile(
                Profiles.FirstOrDefault(item =>
                    string.Equals(item.Host, Host, StringComparison.OrdinalIgnoreCase) &&
                    string.Equals(item.Username, Username, StringComparison.Ordinal))?.Id
                    ?? Guid.NewGuid(),
                string.IsNullOrWhiteSpace(DisplayName) ? "NAS" : DisplayName.Trim(),
                Host.Trim(),
                int.TryParse(Port, out var port) ? port : null,
                Username.Trim(),
                RememberPassword,
                AutoLogin && RememberPassword);
            var input = new ConnectAttempt(
                profile,
                Password,
                string.IsNullOrWhiteSpace(Otp) ? null : Otp,
                RememberPassword);
            var connection = await _connectionResolver.DiscoverAsync(
                input.Profile,
                status =>
                {
                    if (_connectionAttempts.IsCurrent(attempt))
                    {
                        ConnectionStatus = localization.ResolveUserText(status);
                    }
                },
                cancellation.Token).ConfigureAwait(true);
            _connectionAttempts.ThrowIfNotCurrent(attempt);
            ConnectionStatus = localization.Get("StatusNasFoundSigningIn");
            var session = await _api.LoginAsync(
                connection.Profile,
                input.Password,
                input.Otp,
                cancellation.Token).ConfigureAwait(true);
            _connectionAttempts.ThrowIfNotCurrent(attempt);
            if (input.RememberPassword)
            {
                await _sessionStore.SaveAsync(session, cancellation.Token).ConfigureAwait(true);
                _connectionAttempts.ThrowIfNotCurrent(attempt);
                await _passwordStore.SaveAsync(
                    input.Profile.Id,
                    input.Password,
                    cancellation.Token).ConfigureAwait(true);
            }
            else
            {
                await _sessionStore.RemoveAsync(
                    input.Profile.Id,
                    cancellation.Token).ConfigureAwait(true);
                _connectionAttempts.ThrowIfNotCurrent(attempt);
                await _passwordStore.RemoveAsync(
                    input.Profile.Id,
                    cancellation.Token).ConfigureAwait(true);
            }
            _connectionAttempts.ThrowIfNotCurrent(attempt);
            var repository = new DsmRepository(
                connection.Profile,
                session,
                _api,
                connection.Capabilities);
            await TryActivateDesktopDrivesAsync(
                input.Profile.Id,
                repository).ConfigureAwait(true);
            _connectionAttempts.ThrowIfNotCurrent(attempt);
            await SaveProfileForAttemptAsync(input.Profile, attempt).ConfigureAwait(true);
            _connectionAttempts.ThrowIfNotCurrent(attempt);
            if (!input.RememberPassword)
            {
                Password = string.Empty;
                PasswordLoaded?.Invoke(this, string.Empty);
            }
            CompleteConnection(
                input.Profile,
                connection.Profile,
                session,
                repository,
                startDesktopDriveRecovery: true);
        }
        catch (DsmException error)
        {
            if (_connectionAttempts.IsCurrent(attempt))
            {
                ErrorMessage = localization.ErrorMessage(error);
            }
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
        {
            // 用户取消只结束本次尝试，保留已填写内容和本机保存的资料。
        }
        catch
        {
            if (_connectionAttempts.IsCurrent(attempt))
            {
                ErrorMessage = localization.Get("ErrorConnectGeneric");
            }
        }
        finally
        {
            if (_connectionAttempts.End(attempt))
            {
                IsBusy = false;
                ConnectionStatus = null;
            }
            attempt.Dispose();
        }
    }

    public async Task RestoreAsync(NasProfile profile, bool fallbackToPassword = false)
    {
        if (IsBusy)
        {
            return;
        }
        IsBusy = true;
        ErrorMessage = null;
        var localization = LocalizationService.Current;
        ConnectionStatus = localization.Get("StatusRestoringLogin");
        var shouldFallbackToPassword = false;
        var attempt = _connectionAttempts.Begin();
        var cancellation = attempt.Cancellation;
        try
        {
            var session = await _sessionStore.LoadAsync(
                profile.Id,
                cancellation.Token).ConfigureAwait(true);
            _connectionAttempts.ThrowIfNotCurrent(attempt);
            if (session is null)
            {
                throw new DsmException(
                    UserText.Key("ErrorSavedLoginExpired"),
                    UserText.Key("RecoverySignInAgain"),
                    authenticationFailure: true);
            }
            var connection = await _connectionResolver.DiscoverAsync(
                profile,
                status =>
                {
                    if (_connectionAttempts.IsCurrent(attempt))
                    {
                        ConnectionStatus = localization.ResolveUserText(status);
                    }
                },
                cancellation.Token).ConfigureAwait(true);
            _connectionAttempts.ThrowIfNotCurrent(attempt);
            var repository = new DsmRepository(
                connection.Profile,
                session,
                _api,
                connection.Capabilities);
            _ = await repository.ListFilesAsync(
                string.Empty,
                cancellation.Token).ConfigureAwait(true);
            _connectionAttempts.ThrowIfNotCurrent(attempt);
            await TryActivateDesktopDrivesAsync(profile.Id, repository).ConfigureAwait(true);
            _connectionAttempts.ThrowIfNotCurrent(attempt);
            CompleteConnection(
                profile,
                connection.Profile,
                session,
                repository,
                startDesktopDriveRecovery: true);
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
        {
            // 取消恢复不会移除保存的会话、密码或 NAS 资料。
        }
        catch (DsmException error)
        {
            if (_connectionAttempts.IsCurrent(attempt) &&
                !ConnectionRecoveryPolicy.ShouldInvalidateSavedSession(error))
            {
                ErrorMessage = localization.ErrorMessage(error);
            }
            else if (_connectionAttempts.IsCurrent(attempt))
            {
                try
                {
                    await _sessionStore.RemoveAsync(
                        profile.Id,
                        cancellation.Token).ConfigureAwait(true);
                    _connectionAttempts.ThrowIfNotCurrent(attempt);
                    var storedPassword = await _passwordStore.LoadAsync(
                        profile.Id,
                        cancellation.Token).ConfigureAwait(true) ?? string.Empty;
                    _connectionAttempts.ThrowIfNotCurrent(attempt);
                    ApplySelectedProfile(profile, storedPassword);
                    shouldFallbackToPassword =
                        fallbackToPassword &&
                        profile.AutoLogin &&
                        !string.IsNullOrEmpty(storedPassword);
                    if (!shouldFallbackToPassword)
                    {
                        ErrorMessage = string.IsNullOrEmpty(storedPassword)
                            ? $"{localization.ResolveUserText(error.Message)} {localization.Get("RecoveryEnterPasswordAgain")}"
                            : $"{localization.ResolveUserText(error.Message)} {localization.Get("RecoveryPasswordReady")}";
                    }
                }
                catch (OperationCanceledException)
                    when (cancellation.IsCancellationRequested)
                {
                    shouldFallbackToPassword = false;
                }
            }
        }
        finally
        {
            var mayFallback =
                shouldFallbackToPassword &&
                _connectionAttempts.IsCurrent(attempt);
            if (_connectionAttempts.End(attempt))
            {
                IsBusy = false;
                ConnectionStatus = null;
            }
            shouldFallbackToPassword = mayFallback;
            attempt.Dispose();
        }
        if (shouldFallbackToPassword)
        {
            await ConnectAsync().ConfigureAwait(true);
        }
    }

    public void CancelConnection() => _connectionAttempts.CancelCurrent();

    public void ReportProfileActionError() =>
        ErrorMessage = LocalizationService.Current.Get("ProfileActionErrorMessage");

    public async Task SwitchProfileAsync(NasProfile profile)
    {
        if (IsBusy || ActiveProfile?.Id == profile.Id)
        {
            return;
        }
        DisconnectCurrentProfileLocally();
        await SelectProfileAsync(profile).ConfigureAwait(true);
        await RestoreAsync(profile).ConfigureAwait(true);
    }

    public void BeginAddingProfile()
    {
        CancelConnection();
        DisconnectCurrentProfileLocally();
        NewProfile();
    }

    public async Task RemoveProfileAsync(NasProfile profile)
    {
        var mappings = _cloudDrives.Mappings
                     .Where(item => item.ProfileId == profile.Id)
                     .ToArray();
        foreach (var mapping in mappings)
        {
            CancelDesktopDriveTask(mapping);
        }
        foreach (var mapping in mappings)
        {
            await _cloudDrives.RemoveAsync(mapping.Id).ConfigureAwait(true);
        }
        var remainingProfiles = Profiles
            .Where(item => item.Id != profile.Id)
            .ToArray();
        await PersistProfilesSnapshotAsync(remainingProfiles).ConfigureAwait(true);
        await _sessionStore.RemoveAsync(profile.Id).ConfigureAwait(true);
        await _passwordStore.RemoveAsync(profile.Id).ConfigureAwait(true);
        Profiles.Remove(profile);
        RefreshDesktopDriveMappings();
        if (ActiveProfile?.Id == profile.Id)
        {
            DisconnectCurrentProfileLocally();
        }
    }

    public async Task LogoutAsync()
    {
        var profile = ActiveProfile;
        if (profile is not null)
        {
            StopDesktopDriveRecovery();
            _cloudDrives.DisconnectProfile(profile.Id);
            if (Session is not null)
            {
                try
                {
                    await _api.LogoutAsync(
                        ActiveConnectionProfile ?? profile,
                        Session).ConfigureAwait(true);
                }
                catch
                {
                    // NAS 暂时不可达时也必须完成本机退出。
                }
            }
            await _sessionStore.RemoveAsync(profile.Id).ConfigureAwait(true);
            var signedOutProfile = profile with { AutoLogin = false };
            var index = Profiles.IndexOf(profile);
            if (index >= 0)
            {
                Profiles[index] = signedOutProfile;
                await PersistProfilesAsync().ConfigureAwait(true);
            }
            AutoLogin = false;
        }
        ActiveProfile = null;
        ActiveConnectionProfile = null;
        Session = null;
        Repository = null;
        AvailableModules.Clear();
        ConnectionChanged?.Invoke(this, false);
    }

    public async Task AddDesktopDriveAsync(string? folderPath)
    {
        await AddDesktopDriveAsync(
            null,
            folderPath,
            DesktopDriveCachePolicy.Default).ConfigureAwait(true);
    }

    public async Task AddDesktopDriveAsync(
        string? displayName,
        string? folderPath,
        DesktopDriveCachePolicy cachePolicy)
    {
        if (ActiveProfile is null || Repository is null)
        {
            throw new InvalidOperationException("CloudDriveSignInRequired");
        }
        var scope = string.IsNullOrWhiteSpace(folderPath)
            ? DesktopDriveScope.AllShares
            : DesktopDriveScope.Folder(folderPath);
        var name = scope.Kind == DesktopDriveScopeKind.AllShares
            ? ActiveProfile.DisplayName
            : Path.GetFileName(scope.FolderPath?.TrimEnd('/')) ?? ActiveProfile.DisplayName;
        await _cloudDrives.AddAsync(
            ActiveProfile.Id,
            string.IsNullOrWhiteSpace(displayName) ? name : displayName.Trim(),
            scope,
            Repository,
            cachePolicy).ConfigureAwait(true);
        RefreshDesktopDriveMappings();
    }

    public DesktopDriveCacheLocation DesktopDriveCacheLocationForPath(
        string path) =>
        DesktopCloudDriveService.CacheLocationForPath(path);

    public async Task SetDesktopDriveCacheLimitAsync(
        DesktopDriveMapping mapping,
        long limitBytes)
    {
        await _cloudDrives.SetTemporaryCacheLimitAsync(mapping, limitBytes)
            .ConfigureAwait(true);
        RefreshDesktopDriveMappings();
        DesktopDriveProgressChanged?.Invoke(this, EventArgs.Empty);
    }

    public async Task SetDesktopDriveLaunchAtLoginAsync(
        DesktopDriveMapping mapping,
        bool launchAtLogin)
    {
        await _cloudDrives.SetLaunchAtLoginAsync(mapping, launchAtLogin)
            .ConfigureAwait(true);
        RefreshDesktopDriveMappings();
        DesktopDriveProgressChanged?.Invoke(this, EventArgs.Empty);
    }

    public async Task RemoveDesktopDriveAsync(DesktopDriveMapping mapping)
    {
        await _cloudDrives.RemoveAsync(mapping.Id).ConfigureAwait(true);
        RefreshDesktopDriveMappings();
    }

    public void RevealDesktopDrive(DesktopDriveMapping mapping) =>
        _cloudDrives.Reveal(mapping);

    public Task ClearDesktopDriveCacheAsync(DesktopDriveMapping mapping) =>
        _cloudDrives.ClearLocalCacheAsync(mapping);

    public DesktopDriveCacheSummary DesktopDriveCacheSummary(
        DesktopDriveMapping mapping) =>
        _cloudDrives.CacheSummary(mapping);

    public string DesktopDriveCacheVolumeName(
        DesktopDriveMapping mapping) =>
        _cloudDrives.CacheVolumeName(mapping);

    public DesktopDriveMappingRuntime DesktopDriveRuntime(
        DesktopDriveMapping mapping) =>
        _cloudDrives.Runtime(mapping);

    public DesktopDriveOfflineProgress? DesktopDriveProgress(
        DesktopDriveMapping mapping) =>
        _desktopDriveProgress.GetValueOrDefault(mapping.Id);

    public DesktopDrivePlanningProgress? DesktopDrivePlanning(
        DesktopDriveMapping mapping) =>
        _desktopDrivePlanning.GetValueOrDefault(mapping.Id);

    public Task KeepDesktopDriveOfflineAsync(DesktopDriveMapping mapping) =>
        KeepDesktopDriveOfflineCoreAsync(mapping, null);

    public Task KeepDesktopDriveItemsOfflineAsync(
        IReadOnlyList<FileItem> items)
    {
        var mapping = _cloudDrives.MappingContaining(items.Select(item => item.Path))
            ?? throw new InvalidOperationException("CloudDriveNotMapped");
        return KeepDesktopDriveOfflineCoreAsync(mapping, items);
    }

    private async Task KeepDesktopDriveOfflineCoreAsync(
        DesktopDriveMapping mapping,
        IReadOnlyList<FileItem>? items)
    {
        if (Repository is null || _desktopDriveTasks.ContainsKey(mapping.Id))
        {
            return;
        }
        var cancellation = new CancellationTokenSource();
        _desktopDriveTasks[mapping.Id] = cancellation;
        var progress = new Progress<DesktopDriveOfflineProgress>(value =>
        {
            _desktopDriveProgress[mapping.Id] = value;
            DesktopDriveProgressChanged?.Invoke(this, EventArgs.Empty);
        });
        var planning = new Progress<DesktopDrivePlanningProgress>(value =>
        {
            _desktopDrivePlanning[mapping.Id] = value;
            DesktopDriveProgressChanged?.Invoke(this, EventArgs.Empty);
        });
        try
        {
            if (items is null)
            {
                await _cloudDrives.KeepOfflineAsync(
                    mapping,
                    Repository,
                    progress,
                    planning,
                    cancellation.Token).ConfigureAwait(true);
            }
            else
            {
                await _cloudDrives.KeepOfflineAsync(
                    mapping,
                    Repository,
                    items,
                    progress,
                    planning,
                    cancellation.Token).ConfigureAwait(true);
            }
        }
        finally
        {
            _desktopDriveTasks.Remove(mapping.Id);
            DesktopDriveProgressChanged?.Invoke(this, EventArgs.Empty);
            cancellation.Dispose();
        }
    }

    public bool CanManageDesktopDriveItems(IReadOnlyList<FileItem> items) =>
        items.Count > 0 &&
        _cloudDrives.MappingContaining(items.Select(item => item.Path)) is not null;

    public bool DesktopDriveItemsAreKeptOffline(
        IReadOnlyList<FileItem> items)
    {
        var mapping = _cloudDrives.MappingContaining(items.Select(item => item.Path));
        return mapping is not null &&
            items.Count > 0 &&
            items.All(item => _cloudDrives.Runtime(mapping).KeepsOffline(item.Path));
    }

    public async Task ReleaseDesktopDriveItemsOfflineAsync(
        IReadOnlyList<FileItem> items)
    {
        var mapping = _cloudDrives.MappingContaining(items.Select(item => item.Path))
            ?? throw new InvalidOperationException("CloudDriveNotMapped");
        CancelDesktopDriveTask(mapping);
        await _cloudDrives.ReleaseOfflineAsync(mapping, items).ConfigureAwait(true);
        DesktopDriveProgressChanged?.Invoke(this, EventArgs.Empty);
    }

    public void CancelDesktopDriveTask(DesktopDriveMapping mapping)
    {
        if (_desktopDriveTasks.TryGetValue(mapping.Id, out var cancellation))
        {
            cancellation.Cancel();
        }
    }

    public async Task ReleaseDesktopDriveOfflineAsync(
        DesktopDriveMapping mapping)
    {
        CancelDesktopDriveTask(mapping);
        await _cloudDrives.ReleaseOfflineAsync(mapping).ConfigureAwait(true);
        _desktopDriveProgress.Remove(mapping.Id);
        _desktopDrivePlanning.Remove(mapping.Id);
        DesktopDriveProgressChanged?.Invoke(this, EventArgs.Empty);
    }

    public async Task PauseDesktopDriveAsync(DesktopDriveMapping mapping)
    {
        CancelDesktopDriveTask(mapping);
        await _cloudDrives.PauseAsync(mapping).ConfigureAwait(true);
        DesktopDriveProgressChanged?.Invoke(this, EventArgs.Empty);
    }

    public async Task ResumeDesktopDriveAsync(DesktopDriveMapping mapping)
    {
        if (Repository is null)
        {
            throw new InvalidOperationException("CloudDriveSignInRequired");
        }
        await _cloudDrives.ResumeAsync(mapping, Repository).ConfigureAwait(true);
        DesktopDriveProgressChanged?.Invoke(this, EventArgs.Empty);
    }

    public bool IsDesktopDrivePaused(DesktopDriveMapping mapping) =>
        _cloudDrives.Runtime(mapping).IsManuallyPaused;

    public int CurrentDesktopDriveCount =>
        ActiveProfile is { } profile
            ? _cloudDrives.Mappings.Count(item => item.ProfileId == profile.Id)
            : 0;

    public bool AreCurrentDesktopDrivesPaused =>
        ActiveProfile is { } profile &&
        _cloudDrives.Mappings
            .Where(item => item.ProfileId == profile.Id)
            .ToArray() is { Length: > 0 } mappings &&
        mappings.All(mapping =>
            _cloudDrives.Runtime(mapping).IsManuallyPaused);

    public int CurrentDesktopDriveIssueCount =>
        ActiveProfile is { } profile
            ? _cloudDrives.Mappings
                .Where(item => item.ProfileId == profile.Id)
                .Count(mapping =>
                    _cloudDrives.Runtime(mapping).State is not
                        (DesktopDriveMappingState.Available or
                         DesktopDriveMappingState.Paused or
                         DesktopDriveMappingState.Checking))
            : 0;

    public async Task ToggleCurrentDesktopDrivesAsync()
    {
        if (ActiveProfile is not { } profile)
        {
            return;
        }
        var mappings = _cloudDrives.Mappings
            .Where(item => item.ProfileId == profile.Id)
            .ToArray();
        if (mappings.Length == 0)
        {
            return;
        }
        if (mappings.All(mapping =>
                _cloudDrives.Runtime(mapping).IsManuallyPaused))
        {
            var repository = Repository
                ?? throw new InvalidOperationException(
                    "CloudDriveSignInRequired");
            foreach (var mapping in mappings)
            {
                await _cloudDrives.ResumeAsync(mapping, repository)
                    .ConfigureAwait(true);
            }
        }
        else
        {
            foreach (var mapping in mappings)
            {
                await _cloudDrives.PauseAsync(mapping).ConfigureAwait(true);
            }
        }
        DesktopDriveProgressChanged?.Invoke(this, EventArgs.Empty);
    }

    public void Shutdown()
    {
        CancelConnection();
        StopDesktopDriveRecovery();
        foreach (var cancellation in _desktopDriveTasks.Values)
        {
            cancellation.Cancel();
            cancellation.Dispose();
        }
        _desktopDriveTasks.Clear();
        _cloudDrives.Dispose();
    }

    private void CompleteConnection(
        NasProfile profile,
        NasProfile connectionProfile,
        DsmSession session,
        IDsmRepository repository,
        bool startDesktopDriveRecovery)
    {
        ActiveProfile = profile;
        ActiveConnectionProfile = connectionProfile;
        Session = session;
        Repository = repository;
        AvailableModules.Clear();
        foreach (var module in Repository.AvailableModules)
        {
            AvailableModules.Add(module);
        }
        if (startDesktopDriveRecovery)
        {
            StartDesktopDriveRecovery(profile.Id);
        }
        ConnectionChanged?.Invoke(this, true);
    }

    private void DisconnectCurrentProfileLocally()
    {
        StopDesktopDriveRecovery();
        if (ActiveProfile is { } profile)
        {
            foreach (var mapping in _cloudDrives.Mappings
                         .Where(item => item.ProfileId == profile.Id))
            {
                CancelDesktopDriveTask(mapping);
            }
            _cloudDrives.DisconnectProfile(profile.Id);
        }
        ActiveProfile = null;
        ActiveConnectionProfile = null;
        Session = null;
        Repository = null;
        AvailableModules.Clear();
        ConnectionChanged?.Invoke(this, false);
    }

    private void ApplySelectedProfile(NasProfile profile, string storedPassword)
    {
        DisplayName = profile.DisplayName;
        Host = profile.Host;
        Port = profile.Port?.ToString() ?? string.Empty;
        Username = profile.Username;
        Password = storedPassword;
        RememberPassword = !string.IsNullOrEmpty(storedPassword);
        AutoLogin = profile.AutoLogin && RememberPassword;
        PasswordLoaded?.Invoke(this, storedPassword);
        Otp = string.Empty;
        ErrorMessage = null;
        ConnectionStatus = null;
    }

    private async Task LoadProfilesAsync()
    {
        try
        {
            if (!File.Exists(_profilesPath))
            {
                return;
            }
            var content = await File.ReadAllTextAsync(_profilesPath);
            var profiles = JsonSerializer.Deserialize<List<NasProfile>>(content) ?? [];
            foreach (var profile in profiles)
            {
                Profiles.Add(profile);
            }
        }
        catch
        {
            ErrorMessage = LocalizationService.Current.Get("ErrorLoadProfiles");
        }
    }

    private async Task SaveProfileForAttemptAsync(
        NasProfile profile,
        ConnectionAttemptLease attempt)
    {
        var profiles = Profiles
            .Where(item => item.Id != profile.Id)
            .Append(profile)
            .ToArray();
        await PersistProfilesSnapshotAsync(
            profiles,
            attempt.Cancellation.Token).ConfigureAwait(true);
        _connectionAttempts.ThrowIfNotCurrent(attempt);
        var existing = Profiles.FirstOrDefault(item => item.Id == profile.Id);
        if (existing is not null)
        {
            Profiles.Remove(existing);
        }
        Profiles.Add(profile);
    }

    private async Task PersistProfilesAsync()
    {
        await PersistProfilesSnapshotAsync(Profiles.ToArray()).ConfigureAwait(true);
    }

    private async Task PersistProfilesSnapshotAsync(
        IReadOnlyList<NasProfile> profiles,
        CancellationToken cancellationToken = default)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_profilesPath)!);
        var temporaryPath = $"{_profilesPath}.tmp";
        try
        {
            await File.WriteAllTextAsync(
                temporaryPath,
                JsonSerializer.Serialize(profiles),
                cancellationToken).ConfigureAwait(true);
            cancellationToken.ThrowIfCancellationRequested();
            File.Move(temporaryPath, _profilesPath, overwrite: true);
        }
        finally
        {
            if (File.Exists(temporaryPath))
            {
                File.Delete(temporaryPath);
            }
        }
    }

    private void RefreshDesktopDriveMappings()
    {
        DesktopDriveMappings.Clear();
        foreach (var mapping in _cloudDrives.Mappings)
        {
            DesktopDriveMappings.Add(mapping);
        }
    }

    private async Task TryActivateDesktopDrivesAsync(
        Guid profileId,
        IDsmRepository repository)
    {
        try
        {
            await _cloudDrives.ActivateAsync(profileId, repository).ConfigureAwait(true);
        }
        catch
        {
            // 云盘位置稍后可重试，不能把已经成功的 NAS 登录判定为失败。
        }
    }

    private void StartDesktopDriveRecovery(Guid profileId)
    {
        StopDesktopDriveRecovery();
        var cancellation = new CancellationTokenSource();
        _desktopDriveRecoveryCancellation = cancellation;
        _desktopDriveRecoveryTask = Task.Run(async () =>
        {
            var delaySeconds = 15;
            while (!cancellation.IsCancellationRequested)
            {
                try
                {
                    await Task.Delay(
                        TimeSpan.FromSeconds(
                            delaySeconds + Random.Shared.Next(0, 6)),
                        cancellation.Token).ConfigureAwait(false);
                    if (ActiveProfile?.Id != profileId ||
                        Repository is not { } repository)
                    {
                        continue;
                    }
                    await _cloudDrives.ActivateAsync(profileId, repository)
                        .ConfigureAwait(false);
                    var mappings = _cloudDrives.Mappings
                        .Where(item => item.ProfileId == profileId)
                        .ToArray();
                    var hasIssue = mappings.Any(mapping =>
                        _cloudDrives.Runtime(mapping).State is not
                            (DesktopDriveMappingState.Available or
                             DesktopDriveMappingState.Paused));
                    delaySeconds = hasIssue
                        ? Math.Min(delaySeconds * 2, 300)
                        : 300;
                    DesktopDriveProgressChanged?.Invoke(this, EventArgs.Empty);
                }
                catch (OperationCanceledException)
                    when (cancellation.IsCancellationRequested)
                {
                    break;
                }
                catch
                {
                    delaySeconds = Math.Min(delaySeconds * 2, 300);
                }
            }
        }, cancellation.Token);
    }

    private void StopDesktopDriveRecovery()
    {
        _desktopDriveRecoveryCancellation?.Cancel();
        _desktopDriveRecoveryCancellation?.Dispose();
        _desktopDriveRecoveryCancellation = null;
        _desktopDriveRecoveryTask = null;
    }
}
