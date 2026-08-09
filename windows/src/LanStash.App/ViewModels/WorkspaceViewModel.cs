using System.Collections.ObjectModel;
using LanStash.App.Localization;
using LanStash.Domain;

namespace LanStash.App.ViewModels;

public enum WorkspaceCategory
{
    None,
    Overview,
    VirtualMachines,
    Hosts,
    Storage,
    Packages,
    Accounts,
    Logs,
    Connections,
    Networks,
    Images,
    Protection,
    Security,
}

public sealed record WorkspaceCategoryOption(WorkspaceCategory Id, string Title)
{
    public override string ToString() => Title;
}

public sealed class WorkspaceViewModel(AppViewModel app) : ObservableObject
{
    private readonly SemaphoreSlim _mutationGate = new(1, 1);
    private AppModule _module = AppModule.Files;
    private WorkspaceCategory _selectedCategory = WorkspaceCategory.None;
    private string _currentPath = string.Empty;
    private bool _isLoading;
    private string? _message;
    private WorkspaceRow? _selectedItem;
    private CancellationTokenSource? _nasSettingsLoadCancellation;
    private long _nasSettingsLoadGeneration;

    public ObservableCollection<WorkspaceCategoryOption> Categories { get; } = [];
    public ObservableCollection<WorkspaceRow> Items { get; } = [];

    public AppModule Module
    {
        get => _module;
        private set
        {
            if (SetProperty(ref _module, value))
            {
                RaisePropertyChanged(nameof(Title));
                RaisePropertyChanged(nameof(CanCreate));
                RaisePropertyChanged(nameof(CanRename));
                RaisePropertyChanged(nameof(CanDelete));
            }
        }
    }

    public string Title => LocalizationService.Current.ModuleTitle(Module);

    public WorkspaceCategory SelectedCategory
    {
        get => _selectedCategory;
        set
        {
            if (SetProperty(ref _selectedCategory, value) && value != WorkspaceCategory.None)
            {
                _ = ReloadAsync();
                RaiseCommandState();
            }
        }
    }

    public string CurrentPath
    {
        get => _currentPath;
        private set => SetProperty(ref _currentPath, value);
    }

    public bool IsLoading
    {
        get => _isLoading;
        private set => SetProperty(ref _isLoading, value);
    }

    public string? Message
    {
        get => _message;
        private set
        {
            SetProperty(ref _message, value);
            RaisePropertyChanged(nameof(HasMessage));
        }
    }

    public bool HasMessage => !string.IsNullOrWhiteSpace(Message);

    public WorkspaceRow? SelectedItem
    {
        get => _selectedItem;
        set
        {
            if (SetProperty(ref _selectedItem, value))
            {
                RaiseCommandState();
            }
        }
    }

    public bool CanCreate => Module == AppModule.Files;

    public bool CanRename =>
        SelectedItem?.Payload is FileItem && Module == AppModule.Files;

    public bool CanDelete =>
        SelectedItem?.Payload is FileItem && Module == AppModule.Files;

    public bool CanManageOffline =>
        Module == AppModule.Files &&
        SelectedItem?.Payload is FileItem file &&
        app.CanManageDesktopDriveItems([file]);

    public bool SelectedFileIsKeptOffline =>
        SelectedItem?.Payload is FileItem file &&
        app.DesktopDriveItemsAreKeptOffline([file]);

    public async Task ShowModuleAsync(AppModule module)
    {
        if (Module == AppModule.NasSettings && module != AppModule.NasSettings)
        {
            CancelNasSettingsLoad();
        }
        Module = module;
        CurrentPath = string.Empty;
        SelectedItem = null;
        Categories.Clear();
        foreach (var category in CategoriesFor(module))
        {
            Categories.Add(new(
                category,
                LocalizationService.Current.Get(CategoryResourceKey(category))));
        }
        _selectedCategory = Categories.FirstOrDefault()?.Id ?? WorkspaceCategory.None;
        RaisePropertyChanged(nameof(SelectedCategory));
        RaiseCommandState();
        await ReloadAsync();
    }

    public async Task ReloadAsync(string? search = null)
    {
        var repository = app.Repository;
        if (repository is null || IsLoading)
        {
            return;
        }
        var isNasSettingsLoad = Module == AppModule.NasSettings;
        CancellationTokenSource? nasSettingsCancellation = null;
        var nasSettingsGeneration = _nasSettingsLoadGeneration;
        if (isNasSettingsLoad)
        {
            nasSettingsCancellation = new CancellationTokenSource();
            _nasSettingsLoadCancellation = nasSettingsCancellation;
            nasSettingsGeneration = ++_nasSettingsLoadGeneration;
        }
        IsLoading = true;
        Message = null;
        SelectedItem = null;
        try
        {
            var rows = await LoadRowsAsync(
                repository,
                search,
                nasSettingsCancellation?.Token ?? CancellationToken.None);
            if (isNasSettingsLoad && nasSettingsGeneration != _nasSettingsLoadGeneration)
            {
                return;
            }
            Items.Clear();
            foreach (var row in rows)
            {
                Items.Add(row);
            }
            if (Items.Count == 0)
            {
                Message = LocalizationService.Current.Get("EmptyNoItems");
            }
        }
        catch (OperationCanceledException) when (
            isNasSettingsLoad &&
            (nasSettingsCancellation?.IsCancellationRequested == true ||
                nasSettingsGeneration != _nasSettingsLoadGeneration))
        {
        }
        catch (DsmException error)
        {
            if (isNasSettingsLoad && nasSettingsGeneration != _nasSettingsLoadGeneration)
            {
                return;
            }
            Message = LocalizationService.Current.ErrorMessage(error);
        }
        catch
        {
            if (isNasSettingsLoad && nasSettingsGeneration != _nasSettingsLoadGeneration)
            {
                return;
            }
            Message = LocalizationService.Current.Get("ErrorLoadWorkspace");
        }
        finally
        {
            if (!isNasSettingsLoad || nasSettingsGeneration == _nasSettingsLoadGeneration)
            {
                IsLoading = false;
            }
            if (ReferenceEquals(_nasSettingsLoadCancellation, nasSettingsCancellation))
            {
                _nasSettingsLoadCancellation = null;
            }
            nasSettingsCancellation?.Dispose();
        }
    }

    public void CancelNasSettingsLoad()
    {
        _nasSettingsLoadGeneration++;
        var cancellation = _nasSettingsLoadCancellation;
        _nasSettingsLoadCancellation = null;
        cancellation?.Cancel();
        if (Module == AppModule.NasSettings)
        {
            IsLoading = false;
        }
    }

    public async Task OpenSelectedAsync()
    {
        if (Module != AppModule.Files || SelectedItem?.Payload is not FileItem file || !file.IsDirectory)
        {
            return;
        }
        CurrentPath = file.Path;
        await ReloadAsync();
    }

    public async Task GoUpAsync()
    {
        if (Module != AppModule.Files || string.IsNullOrWhiteSpace(CurrentPath))
        {
            return;
        }
        var index = CurrentPath.LastIndexOf('/');
        CurrentPath = index > 0 ? CurrentPath[..index] : string.Empty;
        await ReloadAsync();
    }

    public async Task CreateAsync(string value)
    {
        await MutateAsync(async repository =>
        {
            if (Module == AppModule.Files)
            {
                await repository.CreateFolderAsync(CurrentPath, value);
            }
        });
    }

    public async Task RenameSelectedAsync(string name)
    {
        await MutateAsync(async repository =>
        {
            if (SelectedItem?.Payload is FileItem file)
            {
                await repository.RenameAsync(file.Path, name);
            }
        });
    }

    public async Task DeleteSelectedAsync()
    {
        if (SelectedItem is null)
        {
            return;
        }
        await MutateAsync(async repository =>
        {
            if (Module == AppModule.Files && SelectedItem.Payload is FileItem file)
            {
                await repository.DeleteFilesAsync([file.Path]);
            }
        });
    }

    public Task KeepSelectedOfflineAsync() =>
        SelectedItem?.Payload is FileItem file
            ? app.KeepDesktopDriveItemsOfflineAsync([file])
            : Task.CompletedTask;

    public Task ReleaseSelectedOfflineAsync() =>
        SelectedItem?.Payload is FileItem file
            ? app.ReleaseDesktopDriveItemsOfflineAsync([file])
            : Task.CompletedTask;

    private async Task<IReadOnlyList<WorkspaceRow>> LoadRowsAsync(
        IDsmRepository repository,
        string? search,
        CancellationToken cancellationToken)
    {
        IEnumerable<WorkspaceRow> rows = Module switch
        {
            AppModule.Files => await LoadFilesAsync(repository, search),
            AppModule.Photos => (await repository.ListFilesAsync("/photo")).Items
                .Where(item => !item.IsDirectory)
                .Select(FileRow),
            AppModule.Downloads => [],
            AppModule.VirtualMachines => [],
            AppModule.NasSettings => RowsForNasSettings(
                await repository.LoadNasSettingsAsync(cancellationToken)),
            AppModule.Transfers => [],
            AppModule.Settings => app.ActiveProfile is null
                ? []
                : [new WorkspaceRow(
                    app.ActiveProfile.Id.ToString(),
                    app.ActiveProfile.DisplayName,
                    app.ActiveProfile.Host,
                    LocalizationService.Current.Get("StatusConnected"),
                    "\uEDA2",
                    app.ActiveProfile)],
            _ => [],
        };
        if (!string.IsNullOrWhiteSpace(search) && Module != AppModule.Files)
        {
            rows = rows.Where(item =>
                item.Title.Contains(search, StringComparison.CurrentCultureIgnoreCase) ||
                item.Detail.Contains(search, StringComparison.CurrentCultureIgnoreCase));
        }
        return rows.ToArray();
    }

    private async Task<IReadOnlyList<WorkspaceRow>> LoadFilesAsync(
        IDsmRepository repository,
        string? search)
    {
        var items = string.IsNullOrWhiteSpace(search)
            ? (await repository.ListFilesAsync(CurrentPath)).Items
            : await repository.SearchFilesAsync(CurrentPath, search);
        return items.Select(FileRow).ToArray();
    }

    private IEnumerable<WorkspaceRow> RowsForNasSettings(NasSettingsSnapshot snapshot) =>
        SelectedCategory switch
        {
            WorkspaceCategory.Storage => snapshot.Volumes.Concat(snapshot.Pools).Concat(snapshot.Disks).Select(ResourceRow),
            WorkspaceCategory.Packages => snapshot.Packages.Select(ResourceRow),
            WorkspaceCategory.Accounts => snapshot.Accounts.Concat(snapshot.Groups).Select(ResourceRow),
            WorkspaceCategory.Logs => snapshot.Logs.Select(LogRow),
            WorkspaceCategory.Connections => snapshot.Connections.Select(ResourceRow),
            WorkspaceCategory.Networks => snapshot.Networks.Select(ResourceRow),
            WorkspaceCategory.Security => snapshot.Security.Select(ResourceRow),
            _ => snapshot.System is null
                ? []
                : [new WorkspaceRow(
                    "system",
                    snapshot.System.ServerName,
                    $"{snapshot.System.Model ?? "NAS"} · DSM {snapshot.System.Version ?? LocalizationService.Current.Get("UnknownValue")}",
                    LocalizationService.Current.Get("StatusRunning"),
                    "\uEDA2",
                    snapshot.System)],
        };

    private static WorkspaceRow FileRow(FileItem item) =>
        new(
            item.Path,
            item.Name,
            item.IsDirectory
                ? LocalizationService.Current.Get("ItemFolder")
                : item.Size >= 0
                    ? FormatBytes(item.Size)
                    : LocalizationService.Current.Get("UnknownValue"),
            item.ModifiedAt?.ToLocalTime().ToString("g") ?? string.Empty,
            item.IsDirectory ? "\uE8B7" : "\uE8A5",
            item);

    private static WorkspaceRow ResourceRow(ResourceItem item) =>
        new(
            item.Id,
            LocalizationService.Current.ResolveUserText(item.Name),
            LocalizationService.Current.ResolveUserText(item.Detail),
            StatusText(item.State.ToString()),
            "\uE7F4",
            item);

    private static WorkspaceRow LogRow(LogEntry item) =>
        new(
            item.Id,
            item.Event,
            string.IsNullOrWhiteSpace(item.User) ? LocalizationService.Current.Get("SystemUser") : item.User,
            item.Time?.ToLocalTime().ToString("g") ?? item.Level,
            "\uE9D9",
            item);

    private static WorkspaceCategory[] CategoriesFor(AppModule module) => module switch
    {
        AppModule.VirtualMachines =>
        [
            WorkspaceCategory.VirtualMachines,
            WorkspaceCategory.Hosts,
            WorkspaceCategory.Storage,
            WorkspaceCategory.Networks,
            WorkspaceCategory.Images,
            WorkspaceCategory.Protection,
            WorkspaceCategory.Logs,
        ],
        AppModule.NasSettings =>
        [
            WorkspaceCategory.Overview,
            WorkspaceCategory.Storage,
            WorkspaceCategory.Packages,
            WorkspaceCategory.Accounts,
            WorkspaceCategory.Logs,
            WorkspaceCategory.Connections,
            WorkspaceCategory.Networks,
            WorkspaceCategory.Security,
        ],
        _ => [],
    };

    private static string CategoryResourceKey(WorkspaceCategory category) => category switch
    {
        WorkspaceCategory.Overview => "CategoryOverview",
        WorkspaceCategory.VirtualMachines => "CategoryVirtualMachines",
        WorkspaceCategory.Hosts => "CategoryHosts",
        WorkspaceCategory.Storage => "CategoryStorage",
        WorkspaceCategory.Packages => "CategoryPackages",
        WorkspaceCategory.Accounts => "CategoryAccounts",
        WorkspaceCategory.Logs => "CategoryLogs",
        WorkspaceCategory.Connections => "CategoryConnections",
        WorkspaceCategory.Networks => "CategoryNetworks",
        WorkspaceCategory.Images => "CategoryImages",
        WorkspaceCategory.Protection => "CategoryProtection",
        WorkspaceCategory.Security => "CategorySecurity",
        _ => throw new ArgumentOutOfRangeException(nameof(category)),
    };

    private static string StatusText(string value) => value.ToLowerInvariant() switch
    {
        "running" or "healthy" or "seeding" or "finished" => LocalizationService.Current.Get("StatusNormal"),
        "stopped" => LocalizationService.Current.Get("StatusStopped"),
        "paused" => LocalizationService.Current.Get("StatusPaused"),
        "waiting" => LocalizationService.Current.Get("StatusWaiting"),
        "warning" => LocalizationService.Current.Get("StatusWarning"),
        "error" => LocalizationService.Current.Get("StatusError"),
        _ => LocalizationService.Current.ResolveUserText(value),
    };

    private static string FormatBytes(long bytes)
    {
        string[] units = ["B", "KB", "MB", "GB", "TB"];
        var value = (double)Math.Max(bytes, 0);
        var index = 0;
        while (value >= 1024 && index < units.Length - 1)
        {
            value /= 1024;
            index++;
        }
        return $"{value:0.#} {units[index]}";
    }

    private async Task MutateAsync(Func<IDsmRepository, Task> operation)
    {
        if (!await _mutationGate.WaitAsync(0))
        {
            return;
        }
        try
        {
            var repository = app.Repository ?? throw new InvalidOperationException();
            await operation(repository);
            await ReloadAsync();
        }
        finally
        {
            _mutationGate.Release();
        }
    }

    private void RaiseCommandState()
    {
        RaisePropertyChanged(nameof(CanCreate));
        RaisePropertyChanged(nameof(CanRename));
        RaisePropertyChanged(nameof(CanDelete));
        RaisePropertyChanged(nameof(CanManageOffline));
        RaisePropertyChanged(nameof(SelectedFileIsKeptOffline));
    }
}

public sealed record WorkspaceRow(
    string Id,
    string Title,
    string Detail,
    string Status,
    string Glyph,
    object Payload);
