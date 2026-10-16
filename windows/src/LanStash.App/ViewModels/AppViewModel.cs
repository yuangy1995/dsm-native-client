using System.Collections.ObjectModel;
using System.Text.Json;
using LanStash.App.CloudDrive;
using LanStash.App.Features.Chat;
using LanStash.App.Localization;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.App.ViewModels;

public sealed partial class AppViewModel : ObservableObject
{
    private readonly ISecureSessionStore _sessionStore = new CredentialSessionStore();
    private readonly ISecurePasswordStore _passwordStore = new CredentialPasswordStore();
    private readonly IChatConversationPinStore _chatConversationPins = new FileChatConversationPinStore();
    private readonly IProtectedTaskStore _crossNasStore = WindowsProtectedTaskStore.CrossNas;
    private readonly IProtectedTaskStore _photosUploadsStore = WindowsProtectedTaskStore.PhotosUploads;
    private readonly IProtectedTaskStore _photosManagementStore = WindowsProtectedTaskStore.PhotosManagement;
    private readonly IProtectedTaskStore _officeEditingStore = WindowsProtectedTaskStore.OfficeEditing;
    private readonly IProtectedTaskStore _downloadActionsStore = WindowsProtectedTaskStore.DownloadActions;
    private readonly IProtectedTaskStore _nasManagementStore = WindowsProtectedTaskStore.NasManagement;
    private IDsmApiClient? _api;
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
    private bool _shuttingDown;
    private Task? _shutdownTask;
    private readonly HashSet<Guid> _signingOutProfiles = [];
    private readonly List<Task> _logoutTasks = [];
    private long _profileSelectionGeneration;
    private readonly ConnectionAttemptGate _connectionAttempts = new();
    private readonly Dictionary<Guid, CancellationTokenSource> _desktopDriveTasks = [];
    private readonly Dictionary<Guid, DesktopDriveOfflineProgress> _desktopDriveProgress = [];
    private readonly Dictionary<Guid, DesktopDrivePlanningProgress> _desktopDrivePlanning = [];

    public AppViewModel()
    {
        OfficeEdits = new(ValidateOfficeLocationAsync);
        OfficeEdits.StartMonitoring();
        Features.Settings.AppSettingsService.Current.Changed += ChatSettingsChanged;
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
        if (_shuttingDown) return;
        var generation = ++_profileSelectionGeneration;
        ClearCertificateChallenge();
        var storedPassword = await _passwordStore.LoadAsync(profile.Id).ConfigureAwait(true)
            ?? string.Empty;
        if (_shuttingDown || generation != _profileSelectionGeneration) return;
        ApplySelectedProfile(profile, storedPassword);
    }

    public void NewProfile()
    {
        if (_shuttingDown) return;
        ++_profileSelectionGeneration;
        ClearCertificateChallenge();
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
        if (IsBusy || _shuttingDown || _signingOutProfiles.Count != 0)
        {
            return;
        }
        ClearCertificateChallenge();
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
        await ConnectFrozenAttemptAsync(input, certificateRetry: false).ConfigureAwait(true);
    }

    private async Task ConnectFrozenAttemptAsync(
        ConnectAttempt input,
        bool certificateRetry)
    {
        if (_shuttingDown || _signingOutProfiles.Contains(input.Profile.Id)) return;
        IsBusy = true;
        ErrorMessage = null;
        var localization = LocalizationService.Current;
        ConnectionStatus = localization.Get("StatusCheckingNas");
        var attempt = _connectionAttempts.Begin();
        var cancellation = attempt.Cancellation;
        try
        {
            using var connectionContext = await CreateCertificateConnectionAsync(
                input.Profile.Id,
                cancellation.Token).ConfigureAwait(true);
            var connection = await connectionContext.Resolver.DiscoverAsync(
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
            var session = await connectionContext.Api.LoginAsync(
                connection.Profile,
                input.Password,
                input.Otp,
                connection.Source,
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
                connectionContext.Api,
                connection.Capabilities, _crossNasStore, _photosUploadsStore, _photosManagementStore,
                _officeEditingStore, _downloadActionsStore, _nasManagementStore) { ConfiguredChatProfile = input.Profile, ConfiguredDownloadProfile = input.Profile, ConfiguredNasManagementProfile = input.Profile,
                    ConsoleUsesSystemTrust = !connectionContext.UsesPinnedCertificate || connection.Source == DsmConnectionSource.QuickConnectRelay };
            await repository.InitializeCrossNasRecoveryAsync().ConfigureAwait(true);
            await repository.InitializeOfficeRecoveryAsync().ConfigureAwait(true);
            _connectionAttempts.ThrowIfNotCurrent(attempt);
            await SaveProfileForAttemptAsync(input.Profile, attempt).ConfigureAwait(true);
            _connectionAttempts.ThrowIfNotCurrent(attempt);
            if (!input.RememberPassword)
            {
                Password = string.Empty;
                PasswordLoaded?.Invoke(this, string.Empty);
            }
            DsmRepository.RegisterRepository(connection.Profile.Id, repository);
            CompleteConnection(
                input.Profile,
                connection.Profile,
                session,
                repository,
                connection.Source,
                connectionContext,
                startDesktopDriveRecovery: true);
        }
        catch (CertificateTrustChallengeException error)
        {
            if (_connectionAttempts.IsCurrent(attempt) && !certificateRetry)
            {
                PublishCertificateChallenge(attempt, input, error.Challenge);
            }
            else if (_connectionAttempts.IsCurrent(attempt))
            {
                ErrorMessage = localization.Get("CertificateTrustRetryFailedMessage");
            }
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
        if (IsBusy || _shuttingDown || _signingOutProfiles.Contains(profile.Id))
        {
            return;
        }
        ClearCertificateChallenge();
        await RestoreFrozenAttemptAsync(
            profile,
            fallbackToPassword,
            certificateRetry: false).ConfigureAwait(true);
    }

    private async Task RestoreFrozenAttemptAsync(
        NasProfile profile,
        bool fallbackToPassword,
        bool certificateRetry)
    {
        if (_shuttingDown || _signingOutProfiles.Contains(profile.Id)) return;
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
            using var connectionContext = await CreateCertificateConnectionAsync(
                profile.Id,
                cancellation.Token).ConfigureAwait(true);
            var connection = await connectionContext.Resolver.DiscoverAsync(
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
                connectionContext.Api,
                connection.Capabilities, _crossNasStore, _photosUploadsStore, _photosManagementStore,
                _officeEditingStore, _downloadActionsStore, _nasManagementStore) { ConfiguredChatProfile = profile, ConfiguredDownloadProfile = profile, ConfiguredNasManagementProfile = profile,
                    ConsoleUsesSystemTrust = !connectionContext.UsesPinnedCertificate || connection.Source == DsmConnectionSource.QuickConnectRelay };
            await repository.InitializeCrossNasRecoveryAsync().ConfigureAwait(true);
            await repository.InitializeOfficeRecoveryAsync().ConfigureAwait(true);
            _connectionAttempts.ThrowIfNotCurrent(attempt);
            // 恢复只加载本机会话；实际模块自行处理过期与权限，不能要求套件账号拥有文件权限。
            DsmRepository.RegisterRepository(connection.Profile.Id, repository);
            CompleteConnection(
                profile,
                connection.Profile,
                session,
                repository,
                connection.Source,
                connectionContext,
                startDesktopDriveRecovery: true);
        }
        catch (CertificateTrustChallengeException error)
        {
            if (_connectionAttempts.IsCurrent(attempt) && !certificateRetry)
            {
                PublishCertificateChallenge(attempt, profile, fallbackToPassword, error.Challenge);
            }
            else if (_connectionAttempts.IsCurrent(attempt))
            {
                ErrorMessage = localization.Get("CertificateTrustRetryFailedMessage");
            }
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

    public void CancelConnection()
    {
        _connectionAttempts.CancelCurrent();
        ClearCertificateChallenge();
    }

    public void ReportProfileActionError() =>
        ErrorMessage = LocalizationService.Current.Get("ProfileActionErrorMessage");

    public async Task SwitchProfileAsync(NasProfile profile)
    {
        if (_shuttingDown || _signingOutProfiles.Contains(profile.Id) || ActiveProfile?.Id == profile.Id)
        {
            return;
        }
        if (_connectedWorkspaces.TryGetValue(profile.Id, out var connected) && MatchesConnectedProfile(connected.Profile, profile))
        {
            ActivateConnectedWorkspace(connected);
            return;
        }
        if (IsBusy) return;
        DetachActiveWorkspace();
        var selection = SelectProfileAsync(profile);
        var generation = _profileSelectionGeneration;
        await selection.ConfigureAwait(true);
        if (_shuttingDown || generation != _profileSelectionGeneration) return;
        await RestoreAsync(profile).ConfigureAwait(true);
    }

    internal Task<DsmSession?> LoadSavedSessionForCrossNasAsync(
        Guid profileId,
        CancellationToken cancellationToken) =>
        _sessionStore.LoadAsync(profileId, cancellationToken);

    public void BeginAddingProfile()
    {
        if (_shuttingDown) return;
        CancelConnection();
        DetachActiveWorkspace();
        NewProfile();
    }

    public async Task RemoveProfileAsync(NasProfile profile)
    {
        DisconnectOffice(profile.Id);
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
        await _certificatePins.RemoveAsync(profile.Id).ConfigureAwait(true);
        await _chatConversationPins.RemoveAsync(profile.Id).ConfigureAwait(true);
        ClearCertificateChallenge(profile.Id);
        Profiles.Remove(profile);
        RefreshDesktopDriveMappings();
        if (ActiveProfile?.Id == profile.Id)
        {
            DisconnectCurrentProfileLocally();
        }
        else ReleaseWorkspace(profile.Id);
    }

    public Task LogoutAsync()
    {
        var profile = ActiveProfile;
        if (profile is null || _shuttingDown || !_signingOutProfiles.Add(profile.Id)) return Task.CompletedTask;
        _logoutTasks.RemoveAll(task => task.IsCompletedSuccessfully);
        var logout = LogoutCoreAsync(profile);
        _logoutTasks.Add(logout);
        return logout;
    }

    private async Task LogoutCoreAsync(NasProfile profile)
    {
        var api = _api;
        var session = Session;
        var connectionProfile = ActiveConnectionProfile ?? profile;
        CancelConnection();
        DetachActiveWorkspace();
        try
        {
            try
            {
                await ReleaseWorkspaceAsync(profile.Id, async () =>
                {
                    try
                    {
                        if (api is not null && session is not null)
                            await api.LogoutAsync(connectionProfile, session).ConfigureAwait(true);
                    }
                    catch
                    {
                        // NAS 暂时不可达时也必须完成本机退出。
                    }
                }).ConfigureAwait(true);
            }
            finally
            {
                // 原工作区停止失败也不能留下可被自动恢复的本机会话。
                await _sessionStore.RemoveAsync(profile.Id).ConfigureAwait(true);
                var signedOutProfile = profile with { AutoLogin = false };
                var index = Profiles.ToList().FindIndex(item => item.Id == profile.Id);
                if (index >= 0)
                {
                    Profiles[index] = signedOutProfile;
                    await PersistProfilesAsync().ConfigureAwait(true);
                }
                if (ActiveProfile is null && Host == profile.Host && Username == profile.Username) AutoLogin = false;
            }
        }
        finally { _signingOutProfiles.Remove(profile.Id); }
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
        DesktopDriveCachePolicy cachePolicy,
        bool launchAtLogin = true)
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
            cachePolicy,
            launchAtLogin, ConnectedCloudToken(ActiveProfile.Id, Repository)).ConfigureAwait(true);
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
        var mapping = _cloudDrives.MappingContaining(ActiveProfile?.Id ?? Guid.Empty, items.Select(item => item.Path))
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
        var repository = Repository;
        var cancellation = CancellationTokenSource.CreateLinkedTokenSource(ConnectedCloudToken(mapping.ProfileId, repository));
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
                    repository,
                    progress,
                    planning,
                    cancellation.Token).ConfigureAwait(true);
            }
            else
            {
                await _cloudDrives.KeepOfflineAsync(
                    mapping,
                    repository,
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
        _cloudDrives.MappingContaining(ActiveProfile?.Id ?? Guid.Empty, items.Select(item => item.Path)) is not null;

    public bool DesktopDriveItemsAreKeptOffline(
        IReadOnlyList<FileItem> items)
    {
        var mapping = _cloudDrives.MappingContaining(ActiveProfile?.Id ?? Guid.Empty, items.Select(item => item.Path));
        return mapping is not null &&
            items.Count > 0 &&
            items.All(item => _cloudDrives.Runtime(mapping).KeepsOffline(item.Path));
    }

    public async Task ReleaseDesktopDriveItemsOfflineAsync(
        IReadOnlyList<FileItem> items)
    {
        var mapping = _cloudDrives.MappingContaining(ActiveProfile?.Id ?? Guid.Empty, items.Select(item => item.Path))
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
        await _cloudDrives.ResumeAsync(mapping, Repository, ConnectedCloudToken(mapping.ProfileId, Repository)).ConfigureAwait(true);
        DesktopDriveProgressChanged?.Invoke(this, EventArgs.Empty);
    }

    public bool IsDesktopDrivePaused(DesktopDriveMapping mapping) =>
        _cloudDrives.Runtime(mapping).IsManuallyPaused;

    internal async Task<CloudDriveRefreshSummary> RefreshDesktopDriveFilesAsync(DesktopDriveMapping mapping, CancellationToken token)
    {
        if (ActiveProfile?.Id != mapping.ProfileId || Repository is null)
            throw new InvalidOperationException("CloudDriveSignInRequired");
        var result = await _cloudDrives.RefreshFilesAsync(mapping, token).ConfigureAwait(true);
        DesktopDriveProgressChanged?.Invoke(this, EventArgs.Empty);
        return result;
    }

    internal Task<CloudDriveWritebackOverview> ReadDesktopDriveWritebackAsync(DesktopDriveMapping mapping, CancellationToken token)
    {
        RequireWritebackProfile(mapping);
        return _cloudDrives.ReadWritebackAsync(mapping, token);
    }

    internal async Task<CloudDriveWritebackPreparation> ConfigureDesktopDriveWritebackAsync(DesktopDriveMapping mapping,
        bool enabled, bool confirmed, CancellationToken token)
    {
        RequireWritebackProfile(mapping);
        if (enabled && Repository is IOfficeEditingRepository office && office.HasOfficeSessionWithin(
            mapping.Scope.Kind == DesktopDriveScopeKind.AllShares ? "/" : mapping.Scope.FolderPath!))
            throw new InvalidOperationException("office.cloud-writeback-conflict");
        var result = await _cloudDrives.ConfigureWritebackAsync(mapping, enabled, confirmed, token).ConfigureAwait(true);
        DesktopDriveProgressChanged?.Invoke(this, EventArgs.Empty);
        return result;
    }

    internal async Task RecoverDesktopDriveWritebackAsync(DesktopDriveMapping mapping, CloudDrivePendingChange expected,
        CloudDriveRecoveryAction action, bool confirmed, CancellationToken token)
    {
        RequireWritebackProfile(mapping);
        await _cloudDrives.RecoverWritebackAsync(mapping, Repository!, expected, action, confirmed, token).ConfigureAwait(true);
        DesktopDriveProgressChanged?.Invoke(this, EventArgs.Empty);
    }

    internal Task ExportDesktopDriveWritebackAsync(DesktopDriveMapping mapping, Guid id, string destination, CancellationToken token)
    {
        RequireWritebackProfile(mapping);
        return _cloudDrives.ExportWritebackAsync(mapping, id, destination, token);
    }

    private void RequireWritebackProfile(DesktopDriveMapping mapping)
    {
        if (ActiveProfile?.Id != mapping.ProfileId || Repository is null)
            throw new InvalidOperationException("CloudDriveSignInRequired");
    }

    internal async Task RecoverDesktopDriveRelocationAsync(DesktopDriveMapping mapping, CloudDriveRelocationOperation expected,
        CloudDriveRelocationRecoveryAction action, bool confirmed, CancellationToken token)
    {
        RequireWritebackProfile(mapping);
        await _cloudDrives.RecoverRelocationAsync(mapping, Repository!, expected, action, confirmed, token).ConfigureAwait(true);
        DesktopDriveProgressChanged?.Invoke(this, EventArgs.Empty);
    }

    internal async Task ConfigureDesktopDriveDeletionAsync(DesktopDriveMapping mapping, bool enabled, bool confirmed, CancellationToken token)
    {
        RequireWritebackProfile(mapping);
        await _cloudDrives.ConfigureDeletionAsync(mapping, enabled, confirmed, token).ConfigureAwait(true);
        DesktopDriveProgressChanged?.Invoke(this, EventArgs.Empty);
    }

    internal async Task RecoverDesktopDriveDeletionAsync(DesktopDriveMapping mapping, CloudDriveDeletionOperation expected,
        CloudDriveDeletionRecoveryAction action, bool confirmed, CancellationToken token)
    {
        RequireWritebackProfile(mapping);
        await _cloudDrives.RecoverDeletionAsync(mapping, Repository!, expected, action, confirmed, token).ConfigureAwait(true);
        DesktopDriveProgressChanged?.Invoke(this, EventArgs.Empty);
    }

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

    public Task ShutdownAsync() => _shutdownTask ??= ShutdownCoreAsync();

    private async Task ShutdownCoreAsync()
    {
        _shuttingDown = true;
        CancelConnection();
        ++_profileSelectionGeneration;
        Features.Settings.AppSettingsService.Current.Changed -= ChatSettingsChanged;
        DetachActiveWorkspace();
        foreach (var id in _connectedWorkspaces.Keys.ToArray()) ReleaseWorkspace(id);
        foreach (var cancellation in _officeConnectionReads.Values.ToArray()) cancellation.Cancel();
        await Task.WhenAll(_workspaceDisposals.Concat(_logoutTasks));
        OfficeEdits.Dispose();
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
        DsmConnectionSource connectionSource,
        CertificateConnectionContext connectionContext,
        bool startDesktopDriveRecovery)
    {
        if (_shuttingDown) throw new OperationCanceledException();
        ReleaseWorkspace(profile.Id);
        var chat = repository is IChatRepository { Availability.Status: ChatAvailabilityStatus.Available } chatRepository ? new ChatWorkspaceSession(chatRepository) : null;
        if (chat is not null)
        {
            chat.NotificationsEnabled = Features.Settings.AppSettingsService.Current.Preferences.ChatNotificationsEnabled;
            chat.NotificationRequested += target => ChatNotificationRequested?.Invoke(target);
        }
        _connectedWorkspaces[profile.Id] = new(profile, connectionProfile, session, repository,
            connectionContext.Api, connectionContext.TakeOwnership(), connectionSource, chat);
        if (chat is not null) _ = chat.StartAsync();
        _api = connectionContext.Api;
        ActiveProfile = profile;
        ActiveConnectionProfile = connectionProfile;
        Session = session;
        Repository = repository;
        if (repository is IOfficeEditingRepository office) _ = AttachOfficeRepositoryAsync(office);
        ActiveConnectionSource = connectionSource;
        ClearCertificateChallenge();
        AvailableModules.Clear();
        foreach (var module in Repository.AvailableModules)
        {
            AvailableModules.Add(module);
        }
        if (startDesktopDriveRecovery)
        {
            StartDesktopDriveRecovery(_connectedWorkspaces[profile.Id]);
        }
        ConnectionChanged?.Invoke(this, true);
    }

    private void DisconnectCurrentProfileLocally()
    {
        var profileIdToRelease = ActiveProfile?.Id;
        CancelConnection();
        DetachActiveWorkspace();
        if (profileIdToRelease is { } releaseId) ReleaseWorkspace(releaseId);
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

}
