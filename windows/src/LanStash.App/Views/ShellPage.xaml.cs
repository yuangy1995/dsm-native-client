using LanStash.App.Localization;
using LanStash.App.Features.Settings;
using LanStash.App.Features.Files.Sharing;
using LanStash.App.Features.Files;
using LanStash.App.Features.Files.CopyMove;
using LanStash.App.Features.Files.Locations;
using LanStash.App.Features.Files.Mutations;
using LanStash.App.Features.Files.Recycle;
using LanStash.App.Features.NasAdmin;
using LanStash.App.Features.Transfers;
using LanStash.App.ViewModels;
using LanStash.Domain;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class ShellPage : Page
{
    private readonly AppViewModel _app;
    private readonly AppSettingsService _settings = AppSettingsService.Current;
    private readonly WorkspacePage _workspace;
    private readonly ForegroundTransferCoordinator _transfers = new();
    private readonly WindowsTransferPickerService? _transferPicker;
    private FilesPage? _files;
    private Guid? _filesProfileId;
    private PhotosPage? _photos;
    private Guid? _photosProfileId;
    private IPhotoRepository? _photosRepository;
    private ChatPage? _chat;
    private Guid? _chatProfileId;
    private DownloadStationPage? _downloads;
    private Guid? _downloadsProfileId;
    private ContainerManagerPage? _containers;
    private Guid? _containersProfileId;
    private IContainerManagerRepository? _containerRepository;
    private VirtualMachineManagerPage? _virtualMachines;
    private Guid? _virtualMachinesProfileId;
    private NasDetailsPage? _nasDetails;
    private Guid? _nasDetailsProfileId;
    private INasDetailsRepository? _nasDetailsRepository;
    private TransferActivityPage? _activity;
    private bool _isWindowVisible = true;

    public ShellPage(AppViewModel app)
    {
        InitializeComponent();
        _app = app;
        _workspace = new WorkspacePage(app);
        if (app.ActiveProfile is { } activeProfile && app.Repository is { } repository)
        {
            var profileId = activeProfile.Id.ToString();
            _transfers.ActivateProfile(profileId);
            _transferPicker = new WindowsTransferPickerService(
                repository,
                _transfers,
                new WindowsTransferSavePicker(
                    () => (Application.Current as App)?.MainWindow),
                new WindowsTransferOpenPicker(
                    () => (Application.Current as App)?.MainWindow));
        }
        ContentFrame.Content = _workspace;
        Unloaded += ShellPage_Unloaded;
        var localization = LocalizationService.Current;
        AppNameText.Text = localization.Get("AppName");
        LogoutItem.Content = localization.Get("ActionSignOut");
        if (Navigation.SettingsItem is NavigationViewItem settingsItem)
        {
            settingsItem.Content = localization.Get("ModuleSettings");
        }
        ProfileName.Text = app.ActiveProfile?.DisplayName ?? "NAS";
        AutomationProperties.SetName(
            ProfileMenuButton,
            localization.Get("ProfileMenuAutomationName"));

        _settings.Changed += Settings_Changed;
        RebuildModuleNavigation(routeHiddenSelectionToSettings: false);
    }

    private async void ShellPage_Unloaded(object sender, RoutedEventArgs e)
    {
        try
        {
            try
            {
                await CloseFilesPageAsync();
            }
            catch (OperationCanceledException)
            {
            }
            catch (ObjectDisposedException)
            {
            }
        }
        finally
        {
            _photos?.Dispose();
            _photos = null;
            _photosProfileId = null;
            _photosRepository = null;
            _chat?.Dispose();
            _chat = null;
            _chatProfileId = null;
            _downloads?.Dispose();
            _downloads = null;
            _downloadsProfileId = null;
            _containers?.Dispose();
            _containers = null;
            _containersProfileId = null;
            _containerRepository = null;
            _virtualMachines?.Dispose();
            _virtualMachines = null;
            _virtualMachinesProfileId = null;
            _nasDetails?.Dispose();
            _nasDetails = null;
            _nasDetailsProfileId = null;
            _nasDetailsRepository = null;
            if (_activity is not null)
            {
                await _activity.DisposeAsync();
            }
            _activity = null;
            _transferPicker?.Dispose();
            _transfers.Dispose();
            _settings.Changed -= Settings_Changed;
        }
    }

    private void ProfileMenu_Opening(object sender, object e)
    {
        var localization = LocalizationService.Current;
        ProfileMenu.Items.Clear();
        foreach (var profile in _app.Profiles)
        {
            var item = new ToggleMenuFlyoutItem
            {
                Text = profile.DisplayName,
                IsChecked = profile.Id == _app.ActiveProfile?.Id,
                IsEnabled = profile.Id != _app.ActiveProfile?.Id,
                MinHeight = 44,
                Tag = profile,
            };
            item.Click += SwitchProfile_Click;
            ProfileMenu.Items.Add(item);
        }
        ProfileMenu.Items.Add(new MenuFlyoutSeparator());
        var addItem = new MenuFlyoutItem
        {
            Text = localization.Get("ActionAddNas"),
            Icon = new FontIcon { Glyph = "\uE710" },
            MinHeight = 44,
        };
        addItem.Click += AddProfile_Click;
        ProfileMenu.Items.Add(addItem);
        if (_app.ActiveProfile is not null)
        {
            var deleteItem = new MenuFlyoutItem
            {
                Text = localization.Get("ActionDeleteNas"),
                Icon = new FontIcon { Glyph = "\uE74D" },
                MinHeight = 44,
            };
            deleteItem.Click += DeleteProfile_Click;
            ProfileMenu.Items.Add(deleteItem);
        }
    }

    private async void SwitchProfile_Click(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: NasProfile profile })
        {
            try
            {
                await CloseFilesPageAsync();
                CloseNasDetailsPage();
                await _app.SwitchProfileAsync(profile);
            }
            catch
            {
                _app.ReportProfileActionError();
            }
        }
    }

    private void AddProfile_Click(object sender, RoutedEventArgs e) =>
        _app.BeginAddingProfile();

    private async void DeleteProfile_Click(object sender, RoutedEventArgs e)
    {
        if (_app.ActiveProfile is not { } profile)
        {
            return;
        }
        var localization = LocalizationService.Current;
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = localization.Get("DialogDeleteNasTitle"),
            Content = string.Format(
                localization.Get("DialogDeleteNasMessage"),
                profile.DisplayName),
            PrimaryButtonText = localization.Get("ActionDeleteNas"),
            CloseButtonText = localization.Get("ActionCancel"),
            DefaultButton = ContentDialogButton.Close,
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary)
        {
            try
            {
                await CloseFilesPageAsync();
                CloseNasDetailsPage();
                await _app.RemoveProfileAsync(profile);
            }
            catch
            {
                await ShowProfileActionErrorAsync();
            }
        }
    }

    private async Task ShowProfileActionErrorAsync()
    {
        var localization = LocalizationService.Current;
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = localization.Get("ProfileActionErrorTitle"),
            Content = localization.Get("ProfileActionErrorMessage"),
            CloseButtonText = localization.Get("ActionClose"),
            DefaultButton = ContentDialogButton.Close,
        };
        await dialog.ShowAsync();
    }

    private async void Navigation_SelectionChanged(
        NavigationView sender,
        NavigationViewSelectionChangedEventArgs args)
    {
        if (args.IsSettingsSelected)
        {
            ContentFrame.Content = new AppSettingsPage();
            return;
        }
        if (args.SelectedItem is NavigationViewItem selectedItem
            && ReferenceEquals(selectedItem, LogoutItem))
        {
            var localization = LocalizationService.Current;
            var dialog = new ContentDialog
            {
                XamlRoot = XamlRoot,
                Title = localization.Get("DialogSignOutTitle"),
                Content = localization.Get("DialogSignOutMessage"),
                PrimaryButtonText = localization.Get("DialogSignOutAction"),
                CloseButtonText = localization.Get("ActionCancel"),
                DefaultButton = ContentDialogButton.Close,
            };
            if (await dialog.ShowAsync() == ContentDialogResult.Primary)
            {
                await CloseFilesPageAsync();
                CloseNasDetailsPage();
                await _app.LogoutAsync();
            }
            return;
        }
        if (args.SelectedItemContainer?.Tag is AppModule module)
        {
            if (module == AppModule.Files &&
                _app.Repository is { } repository &&
                _app.ActiveProfile is { } profile &&
                _transferPicker is { } transferPicker)
            {
                var previewRepository = repository as IFilePreviewRepository ??
                    new UnavailableFilePreviewRepository(Guid.Empty);
                var shareRepository = repository as IFileShareLinkRepository;
                if (shareRepository?.ProfileId != profile.Id)
                {
                    shareRepository = null;
                }
                var locationsRepository = repository as IFileLocationsRepository;
                if (locationsRepository?.ProfileId != profile.Id)
                {
                    locationsRepository = null;
                }
                var mutationRepository = repository as IFileMutationRepository;
                if (mutationRepository?.ProfileId != profile.Id)
                {
                    mutationRepository = null;
                }
                var recycleRepository = repository as IFileRecycleRepository;
                if (recycleRepository?.ProfileId != profile.Id)
                {
                    recycleRepository = null;
                }
                if (_files is not null && _filesProfileId != profile.Id)
                {
                    await CloseFilesPageAsync();
                }
                _files ??= new FilesPage(
                    repository,
                    previewRepository,
                    profile.Id.ToString(),
                    transferPicker,
                    shareRepository,
                    FileShareLinkReviewBlocker.Current,
                    locationsRepository,
                    mutationRepository,
                    FileMutationReviewBlocker.Current,
                    recycleRepository: recycleRepository,
                    recycleReviewBlocker: FileRecycleReviewBlocker.Current);
                _filesProfileId = profile.Id;
                ContentFrame.Content = _files;
                return;
            }
            if (module == AppModule.Transfers &&
                _app.ActiveProfile is { } activityProfile &&
                _transferPicker is { } activityPicker)
            {
                var activityRepository = _app.Repository as IDownloadStationRepository;
                if (activityRepository?.ProfileId != activityProfile.Id)
                {
                    activityRepository = new UnavailableDownloadStationRepository(
                        activityProfile.Id);
                }
                _activity ??= new TransferActivityPage(
                    _transfers,
                    activityPicker,
                    activityProfile.Id.ToString(),
                    activityRepository);
                await _activity.SetWindowVisibleAsync(_isWindowVisible);
                ContentFrame.Content = _activity;
                return;
            }
            if (module == AppModule.Photos)
            {
                if (_app.Repository is not IPhotoRepository photoRepository ||
                    _app.ActiveProfile is not { } photoProfile ||
                    _transferPicker is not { } photoTransferPicker ||
                    photoRepository.ProfileId != photoProfile.Id)
                {
                    _photos?.Dispose();
                    _photos = null;
                    _photosProfileId = null;
                    _photosRepository = null;
                    ContentFrame.Content = PhotosPage.CreateUnavailableState();
                    return;
                }
                if (_photos is null || _photosProfileId != photoProfile.Id ||
                    !ReferenceEquals(_photosRepository, photoRepository))
                {
                    _photos?.Dispose();
                    var photoRecycleRepository = _app.Repository as IFileRecycleRepository;
                    if (photoRecycleRepository?.ProfileId != photoProfile.Id)
                    {
                        photoRecycleRepository = null;
                    }
                    var photoLocationsRepository = _app.Repository as IFileLocationsRepository;
                    if (photoLocationsRepository?.ProfileId != photoProfile.Id)
                    {
                        photoLocationsRepository = null;
                    }
                    var photoPreviewRepository = _app.Repository as IFilePreviewRepository;
                    if (photoPreviewRepository?.ProfileId != photoProfile.Id)
                    {
                        photoPreviewRepository = null;
                    }
                    var photoCopyMoveRepository = _app.Repository as IFileCopyMoveRepository;
                    if (photoCopyMoveRepository?.ProfileId != photoProfile.Id)
                    {
                        photoCopyMoveRepository = null;
                    }
                    IFileCopyMoveFolderSource? photoCopyMoveFolderSource = null;
                    if (photoLocationsRepository is not null)
                    {
                        photoCopyMoveFolderSource = new RepositoryFileCopyMoveFolderSource(
                            photoProfile.Id,
                            new RepositoryFileBrowserDataSource(_app.Repository),
                            photoLocationsRepository);
                    }
                    _photos = new PhotosPage(
                        photoRepository,
                        photoProfile.Id.ToString(),
                        photoTransferPicker,
                        locationsRepository: photoLocationsRepository,
                        recycleRepository: photoRecycleRepository,
                        recycleReviewBlocker: FileRecycleReviewBlocker.Current,
                        previewRepository: photoPreviewRepository,
                        copyMoveRepository: photoCopyMoveRepository,
                        copyMoveFolderSource: photoCopyMoveFolderSource,
                        copyMoveReviewBlocker: FileCopyMoveReviewBlocker.Current);
                    _photosProfileId = photoProfile.Id;
                    _photosRepository = photoRepository;
                }
                ContentFrame.Content = _photos;
                return;
            }
            if (module == AppModule.Chat)
            {
                if (_app.Repository is not IChatRepository chatRepository ||
                    _app.ActiveProfile is not { } chatProfile ||
                    chatRepository.ProfileId != chatProfile.Id)
                {
                    _chat?.Dispose();
                    _chat = null;
                    _chatProfileId = null;
                    ContentFrame.Content = new ChatPage(
                        new UnavailableChatRepository(Guid.Empty));
                    return;
                }
                if (_chat is null || _chatProfileId != chatProfile.Id)
                {
                    _chat?.Dispose();
                    _chat = new ChatPage(chatRepository);
                    _chatProfileId = chatProfile.Id;
                }
                await _chat.SetWindowVisibleAsync(_isWindowVisible);
                ContentFrame.Content = _chat;
                return;
            }
            if (module == AppModule.Downloads)
            {
                if (_app.Repository is not IDownloadStationRepository downloadRepository ||
                    _app.ActiveProfile is not { } downloadProfile ||
                    downloadRepository.ProfileId != downloadProfile.Id)
                {
                    _downloads?.Dispose();
                    _downloads = new DownloadStationPage(
                        new UnavailableDownloadStationRepository(Guid.Empty),
                        _transfers);
                    _downloadsProfileId = null;
                    ContentFrame.Content = _downloads;
                    return;
                }
                if (_downloads is null || _downloadsProfileId != downloadProfile.Id)
                {
                    _downloads?.Dispose();
                    _downloads = new DownloadStationPage(downloadRepository, _transfers);
                    _downloadsProfileId = downloadProfile.Id;
                }
                ContentFrame.Content = _downloads;
                return;
            }
            if (module == AppModule.Containers)
            {
                if (_app.ActiveProfile is not { } containerProfile ||
                    _app.Repository is not IContainerManagerRepository containerRepository ||
                    containerRepository.ProfileId != containerProfile.Id)
                {
                    _containers?.Dispose();
                    _containers = new ContainerManagerPage(
                        new UnavailableContainerManagerRepository(
                            _app.ActiveProfile?.Id ?? Guid.Empty));
                    _containersProfileId = null;
                    _containerRepository = null;
                    ContentFrame.Content = _containers;
                    return;
                }
                if (_containers is null ||
                    _containersProfileId != containerProfile.Id ||
                    !ReferenceEquals(_containerRepository, containerRepository))
                {
                    _containers?.Dispose();
                    _containers = new ContainerManagerPage(containerRepository);
                    _containersProfileId = containerProfile.Id;
                    _containerRepository = containerRepository;
                }
                ContentFrame.Content = _containers;
                return;
            }
            if (module == AppModule.VirtualMachines)
            {
                if (_app.ActiveProfile is not { } virtualMachineProfile ||
                    _app.Repository is not IVirtualMachineManagerRepository virtualMachineRepository ||
                    virtualMachineRepository.ProfileId != virtualMachineProfile.Id)
                {
                    _virtualMachines?.Dispose();
                    _virtualMachines = new VirtualMachineManagerPage(
                        new UnavailableVirtualMachineManagerRepository(
                            _app.ActiveProfile?.Id ?? Guid.Empty));
                    _virtualMachinesProfileId = null;
                    ContentFrame.Content = _virtualMachines;
                    return;
                }
                if (_virtualMachines is null ||
                    _virtualMachinesProfileId != virtualMachineProfile.Id)
                {
                    _virtualMachines?.Dispose();
                    _virtualMachines = new VirtualMachineManagerPage(virtualMachineRepository);
                    _virtualMachinesProfileId = virtualMachineProfile.Id;
                }
                ContentFrame.Content = _virtualMachines;
                return;
            }
            if (module == AppModule.NasSettings)
            {
                if (_app.ActiveProfile is not { } nasProfile ||
                    _app.Repository is not INasDetailsRepository nasRepository ||
                    nasRepository.ProfileId != nasProfile.Id)
                {
                    _nasDetails?.Dispose();
                    _nasDetails = new NasDetailsPage(
                        new UnavailableNasDetailsRepository(_app.ActiveProfile?.Id ?? Guid.Empty));
                    _nasDetailsProfileId = null;
                    _nasDetailsRepository = null;
                    ContentFrame.Content = _nasDetails;
                    return;
                }
                if (_nasDetails is null ||
                    _nasDetailsProfileId != nasProfile.Id ||
                    !ReferenceEquals(_nasDetailsRepository, nasRepository))
                {
                    _nasDetails?.Dispose();
                    _nasDetails = new NasDetailsPage(nasRepository);
                    _nasDetailsProfileId = nasProfile.Id;
                    _nasDetailsRepository = nasRepository;
                }
                ContentFrame.Content = _nasDetails;
                return;
            }
            ContentFrame.Content = _workspace;
            await _workspace.ShowModuleAsync(module);
        }
    }

    private async Task CloseFilesPageAsync()
    {
        var files = _files;
        _files = null;
        _filesProfileId = null;
        if (files is null)
        {
            return;
        }
        if (ReferenceEquals(ContentFrame.Content, files))
        {
            ContentFrame.Content = _workspace;
        }
        try
        {
            await files.CloseAsync();
        }
        finally
        {
            files.Dispose();
        }
    }

    internal async Task SetWindowVisibleAsync(bool isVisible)
    {
        _isWindowVisible = isVisible;
        _photos?.SetWindowVisible(isVisible);
        if (_chat is not null)
        {
            await _chat.SetWindowVisibleAsync(isVisible);
        }
        if (_activity is not null)
        {
            await _activity.SetWindowVisibleAsync(isVisible);
        }
    }

    private void CloseNasDetailsPage()
    {
        var page = _nasDetails;
        _nasDetails = null;
        _nasDetailsProfileId = null;
        _nasDetailsRepository = null;
        if (page is null)
        {
            return;
        }
        if (ReferenceEquals(ContentFrame.Content, page))
        {
            ContentFrame.Content = _workspace;
        }
        page.Deactivate();
        page.Dispose();
    }

    private void Settings_Changed(object? sender, AppSettingsChangedEventArgs e)
    {
        if (e.ModuleVisibilityChanged)
        {
            DispatcherQueue.TryEnqueue(() =>
                RebuildModuleNavigation(routeHiddenSelectionToSettings: true));
        }
    }

    private void RebuildModuleNavigation(bool routeHiddenSelectionToSettings)
    {
        var wasSettingsSelected = ReferenceEquals(
            Navigation.SelectedItem,
            Navigation.SettingsItem);
        var selectedModule = (Navigation.SelectedItem as NavigationViewItem)?.Tag is AppModule module
            ? module
            : (AppModule?)null;
        var visibleModules = _app.AvailableModules
            .Where(module => module != AppModule.Settings)
            .Where(_settings.IsModuleVisible)
            .ToArray();
        Navigation.MenuItems.Clear();
        var localization = LocalizationService.Current;
        foreach (var visibleModule in visibleModules)
        {
            Navigation.MenuItems.Add(new NavigationViewItem
            {
                Content = localization.ModuleTitle(visibleModule),
                Icon = new FontIcon { Glyph = visibleModule.Glyph() },
                Tag = visibleModule,
            });
        }

        var restored = selectedModule is { } selected
            ? Navigation.MenuItems.OfType<NavigationViewItem>()
                .FirstOrDefault(item => item.Tag is AppModule itemModule && itemModule == selected)
            : null;
        if (restored is not null)
        {
            Navigation.SelectedItem = restored;
            return;
        }
        if (wasSettingsSelected)
        {
            Navigation.SelectedItem = Navigation.SettingsItem;
            return;
        }
        if (routeHiddenSelectionToSettings && selectedModule is { } hidden)
        {
            DisposeHiddenModulePage(hidden);
            Navigation.SelectedItem = Navigation.SettingsItem;
            ContentFrame.Content = new AppSettingsPage();
            return;
        }
        Navigation.SelectedItem = Navigation.MenuItems.FirstOrDefault();
    }

    private void DisposeHiddenModulePage(AppModule module)
    {
        switch (module)
        {
            case AppModule.Downloads:
                _downloads?.Dispose();
                _downloads = null;
                _downloadsProfileId = null;
                break;
            case AppModule.Containers:
                _containers?.Dispose();
                _containers = null;
                _containersProfileId = null;
                _containerRepository = null;
                break;
            case AppModule.VirtualMachines:
                _virtualMachines?.Dispose();
                _virtualMachines = null;
                _virtualMachinesProfileId = null;
                break;
            case AppModule.NasSettings:
                CloseNasDetailsPage();
                break;
        }
    }

    private sealed class UnavailableNasDetailsRepository(Guid profileId)
        : INasDetailsRepository
    {
        public Guid ProfileId { get; } = profileId;
        public NasDetailsAvailability Availability { get; } = new(
            NasDetailsAvailabilityStatus.Unavailable,
            new HashSet<NasDetailsReadFeature>());

        public Task<NasDetailsSnapshot> LoadDetailsAsync(
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();
    }

    private sealed class UnavailableChatRepository(Guid profileId) : IChatRepository
    {
        public Guid ProfileId { get; } = profileId;
        public ChatAvailability Availability { get; } = new(
            ChatAvailabilityStatus.Unavailable,
            new HashSet<ChatReadFeature>());

        public Task<IReadOnlyList<ChatUser>> ListUsersAsync(
            CancellationToken cancellationToken = default) =>
            Task.FromResult<IReadOnlyList<ChatUser>>([]);

        public Task<IReadOnlyList<ChatUser>> ListConversationMembersAsync(
            string conversationId,
            CancellationToken cancellationToken = default) =>
            Task.FromResult<IReadOnlyList<ChatUser>>([]);

        public Task<IReadOnlyList<ChatConversation>> ListConversationsAsync(
            CancellationToken cancellationToken = default) =>
            Task.FromResult<IReadOnlyList<ChatConversation>>([]);

        public Task<ChatMessagePage> ListMessagesAsync(
            string conversationId,
            string? beforeCursor,
            int limit,
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();

        public Task<ChatTextSendOutcome> SendTextAsync(
            ChatTextSendRequest request,
            CancellationToken cancellationToken = default) =>
            Task.FromResult(new ChatTextSendOutcome(
                new MutationResult(
                    1,
                    MutationResultStatus.Unsupported,
                    "chatTextSend",
                    submitted: false,
                    requiresRefresh: false,
                    new MutationResultCounts(0, 1, 0),
                    MutationErrorCategory.Unsupported,
                    localizationKey: "chat.text-send.unsupported",
                    diagnosticTag: "chat.text-send.unavailable"),
                request.ConversationId,
                request.ClientRequestId,
                null));
    }

    private sealed class UnavailableDownloadStationRepository(Guid profileId)
        : IDownloadStationRepository
    {
        public Guid ProfileId { get; } = profileId;
        public DownloadStationAvailability Availability { get; } = new(
            DownloadStationAvailabilityStatus.Unavailable,
            new HashSet<DownloadStationReadFeature>());

        public Task<DownloadTaskPage> ListTasksAsync(
            int offset,
            int limit,
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();

        public Task<DownloadStationSnapshot> LoadSnapshotAsync(
            int offset,
            int limit,
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();

        public Task<DownloadTaskControlOutcome> ControlTaskAsync(
            DownloadTaskControlRequest request,
            CancellationToken cancellationToken = default) =>
            Task.FromResult(new DownloadTaskControlOutcome(
                new MutationResult(
                    1,
                    MutationResultStatus.Unsupported,
                    request.Action == DownloadTaskControlAction.Pause
                        ? "downloadPause"
                        : "downloadResume",
                    submitted: false,
                    requiresRefresh: false,
                    counts: new MutationResultCounts(0, 1, 0),
                    MutationErrorCategory.Unsupported,
                    localizationKey: "download-station.control.unsupported",
                    diagnosticTag: "download-station.control.unavailable"),
                request.Task.Id,
                null));
    }

    private sealed class UnavailableFilePreviewRepository(Guid profileId)
        : IFilePreviewRepository
    {
        public Guid ProfileId { get; } = profileId;

        public Task<FileRangeReadResult> ReadFileRangeResultAsync(
            string remotePath,
            long offset,
            long length,
            string? expectedContentVersion = null,
            long? expectedTotalLength = null,
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();
    }

    private sealed class UnavailableVirtualMachineManagerRepository(Guid profileId)
        : IVirtualMachineManagerRepository
    {
        public Guid ProfileId { get; } = profileId;
        public VirtualMachineManagerAvailability Availability { get; } = new(
            VirtualMachineManagerAvailabilityStatus.Unavailable,
            new HashSet<VirtualMachineManagerReadFeature>());

        public Task<VirtualMachineManagerSnapshot> LoadSnapshotAsync(
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();
    }

    private sealed class UnavailableContainerManagerRepository(Guid profileId)
        : IContainerManagerRepository
    {
        public Guid ProfileId { get; } = profileId;
        public ContainerManagerAvailability Availability { get; } = new(
            ContainerManagerAvailabilityStatus.Unavailable);

        public Task<ContainerManagerSnapshot> LoadSnapshotAsync(
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();
    }
}
