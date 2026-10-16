using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views.Photos;

/// <summary>目录与相册独立加载，未编辑的限制保留原值；所有写入仍由原 Repository 处理。</summary>
internal sealed class SynologyPhotoRequestEditor : StackPanel, IDisposable
{
    private readonly LocalizationService _l = LocalizationService.Current;
    private readonly ISynologyPhotosRepository _repository;
    private readonly SynologyPhotoRequestSettings _initial;
    private readonly bool _new, _managesShared;
    private readonly CancellationTokenSource _cancel = new();
    private readonly SynologyPhotoSpace[] _spaces;
    private readonly TextBox _subject, _description;
    private readonly ComboBox _space, _album, _expiry;
    private readonly CheckBox _defaultFolder, _sizeEnabled;
    private readonly NumberBox _size;
    private readonly CalendarDatePicker _date;
    private readonly TextBlock _folderPath = new() { TextWrapping = TextWrapping.Wrap };
    private readonly TextBlock _folderMessage = new() { TextWrapping = TextWrapping.Wrap };
    private readonly TextBlock _albumMessage = new() { TextWrapping = TextWrapping.Wrap };
    private readonly TextBlock _albumRisk = new() { TextWrapping = TextWrapping.Wrap };
    private readonly StackPanel _folderPicker = new() { Spacing = 8, Visibility = Visibility.Collapsed };
    private readonly ListView _folders = new() { MaxHeight = 180, DisplayMemberPath = nameof(SynologyPhotoCollection.Name), SelectionMode = ListViewSelectionMode.Single };
    private readonly List<SynologyPhotoCollection> _folderRows = [];
    private readonly List<SynologyPhotoFolder> _history = [];
    private readonly Button _browse, _back, _open, _more, _folderRetry, _useFolder, _albumRetry, _createAlbum, _reviewAlbum;
    private readonly TextBox _albumName;
    private readonly TextBlock _albumCreationMessage = new() { TextWrapping = TextWrapping.Wrap };
    private SynologyPhotoFolder? _selectedFolder, _browsedFolder;
    private SynologyPhotoAlbumChange? _albumCreation;
    private bool _disposed, _folderBusy, _albumBusy, _creating, _sizeEdited, _initializing = true, _hasMore;
    private long _folderGeneration;
    private sealed record AlbumChoice(long? Id, string? Passphrase, string Name, bool? Shared) { public override string ToString() => Name; }
    internal event Action? Changed;
    internal event Action? AlbumHistoryRequested;
    internal bool CreatingAlbum => _creating;
    internal SynologyPhotoRequestEditor(ISynologyPhotosRepository repository, SynologyPhotoRequestSettings initial, bool isNew,
        IReadOnlyList<SynologyPhotoSpace> spaces, bool managesShared, string? albumName = null)
    {
        _repository = repository; _initial = initial; _new = isNew; _managesShared = managesShared;
        _spaces = spaces.Contains(initial.Space) ? spaces.ToArray() : [initial.Space, .. spaces]; Spacing = 12;
        _subject = new() { Header = _l.Get("PhotosRequestSubject"), Text = initial.Subject, MaxLength = 50 };
        _description = new() { Header = _l.Get("PhotosRequestDescription"), Text = initial.Description, MaxLength = 100, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 70 };
        _space = new() { Header = _l.Get("PhotosChooseSource"), HorizontalAlignment = HorizontalAlignment.Stretch,
            ItemsSource = _spaces.Select(space => _l.Get(space == SynologyPhotoSpace.Personal ? "PhotosSourcePersonal" : "PhotosSourceShared")).ToArray(), SelectedIndex = Array.IndexOf(_spaces, initial.Space),
            Visibility = _spaces.Length > 1 ? Visibility.Visible : Visibility.Collapsed };
        _defaultFolder = new() { Content = _l.Get("PhotosRequestDefaultFolder"), IsChecked = isNew && initial.FolderId is null && CanDefault(initial.Space) };
        if (initial.FolderId is { } folder) _selectedFolder = new(initial.Space, folder, 0, initial.FolderPath);
        _browse = Button("PhotosRequestChooseFolder"); _back = Button("PhotosBack"); _open = Button("PhotosOpenFolder"); _more = Button("PhotosLoadOlder");
        _folderRetry = Button("PhotosRefresh"); _useFolder = Button("PhotosRequestUseFolder");
        AutomationProperties.SetName(_folders, _l.Get("PhotosChooseDestination"));
        var navigation = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 }; navigation.Children.Add(_back); navigation.Children.Add(_open);
        foreach (var child in new FrameworkElement[] { navigation, _folders, _more, _folderMessage, _folderRetry, _useFolder }) _folderPicker.Children.Add(child);
        _album = new() { Header = _l.Get("PhotosRequestAlbum"), HorizontalAlignment = HorizontalAlignment.Stretch };
        _album.ItemsSource = InitialAlbums(albumName); _album.SelectedIndex = initial.AlbumId is null && initial.AlbumPassphrase is null ? 0 : 1;
        _albumRetry = Button("PhotosRequestReloadAlbums");
        _albumName = new() { Header = _l.Get("PhotosAlbumName"), MaxLength = 255 };
        _createAlbum = Button("PhotosCreateAlbum"); _reviewAlbum = Button("PhotosRefresh");
        var history = Button("PhotosAlbumChanges"); history.Click += (_, _) => AlbumHistoryRequested?.Invoke();
        var createPanel = new StackPanel { Spacing = 8 };
        foreach (var child in new FrameworkElement[] { _albumName, _createAlbum, _albumCreationMessage, _reviewAlbum, history }) createPanel.Children.Add(child);
        var createExpander = new Expander { Header = _l.Get("PhotosCreateAlbum"), Content = createPanel, HorizontalAlignment = HorizontalAlignment.Stretch,
            Visibility = repository.SupportsAlbumManagement && spaces.Contains(SynologyPhotoSpace.Personal) ? Visibility.Visible : Visibility.Collapsed };
        _expiry = new() { Header = _l.Get("PhotosShareExpiration"), ItemsSource = new[] { _l.Get("PhotosShareKeep"), _l.Get("PhotosShareNoExpiration"), _l.Get("PhotosShareChooseDate") },
            SelectedIndex = isNew ? 1 : 0, HorizontalAlignment = HorizontalAlignment.Stretch };
        _date = new() { Header = _l.Get("PhotosShareExpiration"), PlaceholderText = _l.Get("PhotosShareChooseDate"), Language = _l.ResolvedLanguage, HorizontalAlignment = HorizontalAlignment.Stretch };
        _sizeEnabled = new() { Content = _l.Get("PhotosRequestLimitSize"), IsChecked = initial.SizeLimit > 0 };
        _size = new() { Header = _l.Get("PhotosRequestSizeMiB"), Minimum = 1, Maximum = 3000, SmallChange = 1, LargeChange = 25,
            Value = initial.SizeLimit > 0 ? initial.SizeLimit / 1_048_576 : 25, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact };
        foreach (var child in new FrameworkElement[] { _subject, _description, _space, _defaultFolder, _folderPath, _browse, _folderPicker, _album,
            _albumRisk, _albumMessage, _albumRetry, createExpander, _expiry }) Children.Add(child);
        if (initial.Expiration > 0)
        {
            try { Children.Add(new TextBlock { Text = _l.Format("PhotosShareCurrentExpiry", DateTimeOffset.FromUnixTimeSeconds(initial.Expiration).ToLocalTime()), TextWrapping = TextWrapping.Wrap }); }
            catch (ArgumentOutOfRangeException) { }
        }
        Children.Add(_date); Children.Add(_sizeEnabled); Children.Add(_size);
        _subject.TextChanged += (_, _) => Render(); _description.TextChanged += (_, _) => Render();
        _space.SelectionChanged += (_, _) =>
        {
            if (_initializing) return; _folderGeneration++; _folderBusy = false; _selectedFolder = _browsedFolder = null;
            _history.Clear(); _folderRows.Clear(); _folders.ItemsSource = null; _folderPicker.Visibility = Visibility.Collapsed;
            _defaultFolder.IsChecked = _new && CanDefault(Space); Render();
        };
        _defaultFolder.Checked += (_, _) => Render(); _defaultFolder.Unchecked += (_, _) => Render();
        _browse.Click += async (_, _) => { _folderPicker.Visibility = Visibility.Visible; await LoadFolderAsync(null); };
        _back.Click += async (_, _) => { if (_history.Count > 1) await LoadFolderAsync(_history[^2], back: true); };
        _open.Click += async (_, _) =>
        { if (_folders.SelectedItem is SynologyPhotoCollection { ParentId: { } parent, Path: { } path } folder) await LoadFolderAsync(new(folder.Space, folder.Id, parent, path)); };
        _more.Click += async (_, _) => await LoadFolderAsync(_browsedFolder, append: true);
        _folderRetry.Click += async (_, _) => await LoadFolderAsync(_browsedFolder);
        _folders.SelectionChanged += (_, _) => Render();
        _useFolder.Click += (_, _) =>
        {
            if (_browsedFolder is null || _folderBusy) return; _selectedFolder = _browsedFolder; _defaultFolder.IsChecked = false;
            _folderPicker.Visibility = Visibility.Collapsed; Render();
        };
        _album.SelectionChanged += (_, _) => Render(); _albumRetry.Click += async (_, _) => await LoadAlbumsAsync();
        _expiry.SelectionChanged += (_, _) => Render(); _date.DateChanged += (_, _) => Render();
        _sizeEnabled.Checked += (_, _) => { if (!_initializing) _sizeEdited = true; Render(); };
        _sizeEnabled.Unchecked += (_, _) => { if (!_initializing) _sizeEdited = true; Render(); };
        _size.ValueChanged += (_, _) => { if (!_initializing) _sizeEdited = true; Render(); };
        _albumName.TextChanged += (_, _) => Render(); _createAlbum.Click += async (_, _) => await CreateAlbumAsync(false);
        _reviewAlbum.Click += async (_, _) => await CreateAlbumAsync(true);
        _initializing = false; Render();
    }
    private Button Button(string key) => new() { Content = _l.Get(key), MinHeight = 36 };
    private SynologyPhotoSpace Space => _space.SelectedIndex >= 0 ? _spaces[_space.SelectedIndex] : _initial.Space;
    private bool CanDefault(SynologyPhotoSpace space) => space == SynologyPhotoSpace.Personal || _managesShared;
    private AlbumChoice[] InitialAlbums(string? name) => _initial.AlbumId is null && _initial.AlbumPassphrase is null ? [new(null, null, _l.Get("PhotosUploadNoAlbum"), null)] :
        [new(null, null, _l.Get("PhotosUploadNoAlbum"), null), new(_initial.AlbumId, _initial.AlbumPassphrase, name ?? _l.Get("PhotosRequestSavedAlbum"), null)];
    private void Render()
    {
        if (_initializing || _disposed) return;
        _defaultFolder.Visibility = CanDefault(Space) ? Visibility.Visible : Visibility.Collapsed;
        var useDefault = CanDefault(Space) && _defaultFolder.IsChecked == true;
        _folderPath.Text = useDefault ? SynologyPhotoRequestSettings.DefaultFolderPath(_subject.Text) : _selectedFolder?.Path ?? (_new || Space != _initial.Space ? _l.Get("PhotosRequestNoFolder") : _initial.FolderPath);
        _back.IsEnabled = !_folderBusy && _history.Count > 1; _open.IsEnabled = !_folderBusy && _folders.SelectedItem is SynologyPhotoCollection;
        _folderRetry.IsEnabled = !_folderBusy; _useFolder.IsEnabled = !_folderBusy && _browsedFolder is not null;
        _more.IsEnabled = !_folderBusy; _more.Visibility = _hasMore ? Visibility.Visible : Visibility.Collapsed;
        _folderMessage.Visibility = _folderMessage.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        _albumRetry.IsEnabled = !_albumBusy; _album.IsEnabled = !_albumBusy;
        _albumMessage.Visibility = _albumMessage.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        _albumRisk.Text = _album.SelectedItem is AlbumChoice { Shared: false } ? _l.Get("PhotosRequestPrivateAlbum") : "";
        _albumRisk.Visibility = _albumRisk.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        _date.Visibility = _expiry.SelectedIndex == 2 ? Visibility.Visible : Visibility.Collapsed;
        _size.Visibility = _sizeEnabled.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
        _createAlbum.Content = _l.Get(_albumCreation is { State: SynologyPhotoChangeState.Failed } ? "PhotosAlbumContinue" : "PhotosCreateAlbum");
        _createAlbum.IsEnabled = !_creating && _repository.SharingSafety.Requests && (_albumCreation is null ? !string.IsNullOrWhiteSpace(_albumName.Text) : _albumCreation.CanContinue);
        _albumName.IsEnabled = !_creating && _albumCreation is null;
        _reviewAlbum.Visibility = _albumCreation?.Pending == true ? Visibility.Visible : Visibility.Collapsed; _reviewAlbum.IsEnabled = !_creating;
        _albumCreationMessage.Visibility = _albumCreationMessage.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        Changed?.Invoke();
    }
    internal SynologyPhotoRequestSettings Input()
    {
        if (_disposed || _creating) throw new ArgumentException(); var initial = _initial;
        var useDefault = CanDefault(Space) && _defaultFolder.IsChecked == true;
        var selected = _selectedFolder;
        if (!useDefault && selected is null && (_new || Space != initial.Space || initial.FolderPath.Length == 0)) throw new ArgumentException();
        var album = _album.SelectedItem as AlbumChoice ?? throw new ArgumentException();
        var size = !_sizeEdited ? initial.SizeLimit : _sizeEnabled.IsChecked != true ? 0 : double.IsFinite(_size.Value) && _size.Value == Math.Truncate(_size.Value)
            ? checked((long)_size.Value * 1_048_576) : throw new ArgumentException();
        var result = new SynologyPhotoRequestSettings(_subject.Text.Trim(), _description.Text, Space,
            useDefault ? SynologyPhotoRequestSettings.DefaultFolderPath(_subject.Text) : selected?.Path ?? initial.FolderPath)
        {
            FolderId = useDefault ? null : selected?.Id ?? initial.FolderId, AlbumId = album.Id, AlbumPassphrase = album.Passphrase,
            Expiration = _expiry.SelectedIndex switch { 0 => initial.Expiration, 1 => 0, _ => SynologyPhotoSharingEditor.ExpirationAtDayEnd(_date.Date) }, SizeLimit = size,
        };
        if (!result.IsValid) throw new ArgumentException(); return result;
    }
    internal async Task LoadAlbumsAsync(long? select = null)
    {
        if (_disposed || _albumBusy) return; _albumBusy = true; _albumMessage.Text = _l.Get("PhotosLoadingDescription"); Render();
        try
        {
            var values = await _repository.PhotoRequestAlbumsAsync(_cancel.Token); if (_disposed) return;
            var previous = _album.SelectedItem as AlbumChoice;
            var choices = new List<AlbumChoice> { new(null, null, _l.Get("PhotosUploadNoAlbum"), null) };
            choices.AddRange(values.Select(item => new AlbumChoice(item.AlbumId, item.Passphrase, item.Name, item.Shared)));
            if (previous is { } saved && (saved.Id is not null || saved.Passphrase is not null) && !choices.Any(item => item.Id == saved.Id && item.Passphrase == saved.Passphrase)) choices.Add(saved);
            _album.ItemsSource = choices;
            _album.SelectedIndex = Math.Max(0, choices.FindIndex(item => select is { } id ? item.Id == id : item.Id == previous?.Id && item.Passphrase == previous?.Passphrase));
            _albumMessage.Text = values.Count == 0 ? _l.Get("PhotosRequestNoAlbums") : "";
        }
        catch (Exception error) { if (!_disposed) _albumMessage.Text = Error(error); }
        finally { _albumBusy = false; Render(); }
    }
    private async Task LoadFolderAsync(SynologyPhotoFolder? target, bool append = false, bool back = false)
    {
        if (_disposed || _folderBusy) return; var generation = ++_folderGeneration; var space = Space; _folderBusy = true;
        _folderMessage.Text = _l.Get("PhotosLoadingDescription"); Render();
        try
        {
            var folder = await _repository.FolderAsync(target?.Id, space, _cancel.Token);
            if (target is not null && (folder.Id != target.Id || folder.Space != target.Space || folder.Path != target.Path || folder.ParentId != target.ParentId)) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
            var rows = await _repository.FoldersAsync(folder.Id, append ? _folderRows.Count : 0, 100, _cancel.Token, space);
            var seen = append ? _folderRows.Select(item => item.Id).ToHashSet() : [];
            if (rows.Count > 100 || rows.Any(item => item.Space != space || item.ParentId != folder.Id || item.Path != folder.Path.TrimEnd('/') + "/" + item.Name || !seen.Add(item.Id)))
                throw new SynologyPhotoException(SynologyPhotoFailure.InvalidResponse);
            if (_disposed || generation != _folderGeneration) return;
            if (!append)
            {
                _folderRows.Clear(); if (target is null) _history.Clear(); else if (back) _history.RemoveAt(_history.Count - 1);
                if (_history.Count == 0 || _history[^1].Id != folder.Id) _history.Add(folder);
            }
            _folderRows.AddRange(rows); _browsedFolder = folder; _hasMore = rows.Count == 100; _folders.ItemsSource = _folderRows.ToArray();
            _folderMessage.Text = _l.Format("PhotosRequestBrowsingFolder", folder.Path);
        }
        catch (Exception error) { if (!_disposed && generation == _folderGeneration) { _browsedFolder = null; _folderMessage.Text = Error(error); } }
        finally { if (generation == _folderGeneration) { _folderBusy = false; Render(); } }
    }
    private async Task CreateAlbumAsync(bool review)
    {
        if (_disposed || _creating || !review && !_createAlbum.IsEnabled) return; _creating = true; Render();
        try
        {
            var result = _albumCreation is { } prior ? review ? await _repository.ReviewAlbumChangeAsync(prior.Id) : await _repository.ContinueAlbumChangeAsync(prior.Id) :
                await _repository.EditAlbumAsync(Guid.NewGuid(), new(SynologyPhotoAlbumEditKind.Create) { Name = _albumName.Text, Photos = [] });
            _albumCreation = result; if (_disposed) return;
            _albumCreationMessage.Text = _l.Get(result.Pending ? "PhotosAlbumProcessing" : result.State == SynologyPhotoChangeState.Completed ? "PhotosRequestAlbumCreated" : "PhotosAlbumFailed");
            if (result is { State: SynologyPhotoChangeState.Completed, Result: { } created })
            {
                // 本次已完整确认的新相册先按编号选择，候选列表暂时不可读也不丢失用户目标。
                var choices = (_album.ItemsSource as IEnumerable<AlbumChoice>)?.ToList() ?? [];
                if (!choices.Any(item => item.Id == created.Id && item.Passphrase is null)) choices.Add(new(created.Id, null, created.Name, created.Shared));
                _album.ItemsSource = choices; _album.SelectedIndex = choices.FindIndex(item => item.Id == created.Id && item.Passphrase is null);
                await LoadAlbumsAsync(created.Id);
            }
        }
        catch (Exception error) { if (!_disposed) _albumCreationMessage.Text = Error(error); }
        finally { _creating = false; Render(); }
    }
    private string Error(Exception error) => _l.Get(error is SynologyPhotoException { Failure: SynologyPhotoFailure.Permission } ? "PhotosEditPermission" :
        error is SynologyPhotoException { Failure: SynologyPhotoFailure.TargetChanged } ? "PhotosEditTargetChanged" : "PhotosRequestLoadFailed");
    public void Dispose() { if (_disposed) return; _disposed = true; _cancel.Cancel(); _cancel.Dispose(); }
}
