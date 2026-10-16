using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace LanStash.App.Views.Photos;

internal enum PhotoSimilarAction { TopPick, Remove, Ungroup, Cleanup }
internal sealed class SynologyPhotoSimilarEditor : StackPanel
{
    private readonly Localization.LocalizationService _l = Localization.LocalizationService.Current;
    private readonly IReadOnlyList<SynologyPhotoSimilarDetail> _groups;
    private readonly ComboBox _action;
    private readonly TextBox _search;
    private readonly ListView _list;
    private readonly TextBlock _selection, _empty;
    private readonly HashSet<long> _selected = [];
    private bool _rendering;
    private readonly bool _batch;
    private sealed record Row(SynologyPhoto Photo, string Title);
    internal event Action? Changed;
    internal PhotoSimilarAction Action => _batch ? PhotoSimilarAction.Ungroup : (PhotoSimilarAction)_action.SelectedIndex;
    internal IReadOnlyList<SynologyPhotoSimilarDetail> Groups => _groups;
    internal void AttachThumbnails(DataTemplate template, ISynologyPhotosRepository repository, CancellationToken token)
    {
        _list.DisplayMemberPath = ""; _list.ItemTemplate = template; _list.ContainerContentChanging += Load;
        async void Load(ListViewBase sender, ContainerContentChangingEventArgs args)
        {
            if (args.ItemContainer is not { } container) return;
            if (args.InRecycleQueue || args.Phase == 0)
            { if (Image(container) is { } old) old.Source = null; if (!args.InRecycleQueue) args.RegisterUpdateCallback(1, Load); return; }
            if (token.IsCancellationRequested || args.Item is not Row row || Image(container) is not { } image) return;
            try
            {
                var bytes = await repository.ThumbnailAsync(row.Photo, cancellationToken: token);
                var bitmap = await SynologyPhotoImages.DecodeAsync(bytes, 160, token);
                if (!token.IsCancellationRequested && ReferenceEquals(container.Content, row)) image.Source = bitmap.Value;
            }
            catch (Exception) { /* 缩略图失败不影响选择与打开原预览。 */ }
        }
        static Image? Image(DependencyObject value)
        {
            if (value is Image image) return image;
            for (var index = 0; index < VisualTreeHelper.GetChildrenCount(value); index++) if (Image(VisualTreeHelper.GetChild(value, index)) is { } child) return child;
            return null;
        }
    }
    internal long[] Selected => _groups.SelectMany(group => group.Photos).Where(photo => _selected.Contains(photo.Id.ItemId)).Select(photo => photo.Id.ItemId).ToArray();
    internal SynologyPhoto? OpenPhoto => Selected.Length == 1 ? _groups.SelectMany(group => group.Photos).Single(photo => photo.Id.ItemId == Selected[0]) : null;
    internal SynologyPhotoSimilarEditor(IReadOnlyList<SynologyPhotoSimilarDetail> groups, bool batch = false)
    {
        _groups = groups; _batch = batch || groups.Count > 1; Spacing = 12;
        Children.Add(new TextBlock { Text = _l.Format("PhotosSimilarSummary", groups.Count, groups.Sum(detail => detail.Photos.Count)), TextWrapping = TextWrapping.Wrap });
        _action = new ComboBox { Header = _l.Get("PhotosSimilarAction"), ItemsSource = new[] { _l.Get("PhotosSimilarTopPick"), _l.Get("PhotosSimilarRemove"), _l.Get("PhotosSimilarUngroup"), _l.Get("PhotosSimilarCleanup") },
            SelectedIndex = _batch ? 2 : 0, HorizontalAlignment = HorizontalAlignment.Stretch, Visibility = _batch ? Visibility.Collapsed : Visibility.Visible };
        _search = new TextBox { Header = _l.Get("PhotosSimilarFind") };
        _list = new ListView { SelectionMode = ListViewSelectionMode.Multiple, DisplayMemberPath = nameof(Row.Title), MaxHeight = 280 };
        AutomationProperties.SetName(_list, _l.Get("PhotosSimilarChoose"));
        _selection = new TextBlock { TextWrapping = TextWrapping.Wrap }; _empty = new TextBlock { TextWrapping = TextWrapping.Wrap };
        foreach (var control in new FrameworkElement[] { _action, _search, _list, _empty, _selection }) Children.Add(control);
        _search.TextChanged += (_, _) => Render(); _action.SelectionChanged += (_, _) => { RenderSelection(); Changed?.Invoke(); };
        _list.SelectionChanged += (_, args) =>
        {
            if (_rendering) return;
            foreach (var row in args.RemovedItems.OfType<Row>()) _selected.Remove(row.Photo.Id.ItemId);
            foreach (var row in args.AddedItems.OfType<Row>()) _selected.Add(row.Photo.Id.ItemId);
            RenderSelection(); Changed?.Invoke();
        };
        Render();
    }
    internal SynologyPhotoRecognitionEdit? Input()
    {
        if (Action == PhotoSimilarAction.Cleanup || Action == PhotoSimilarAction.TopPick && (Selected.Length != 1 || Selected[0] == _groups[0].Group.TopPickId) ||
            Action == PhotoSimilarAction.Remove && Selected.Length == 0) return null;
        return new(Action switch { PhotoSimilarAction.TopPick => SynologyPhotoRecognitionKind.SimilarTopPick, PhotoSimilarAction.Remove => SynologyPhotoRecognitionKind.SimilarRemove, _ => SynologyPhotoRecognitionKind.SimilarUngroup }, [])
        { Space = _groups[0].Group.Space, SimilarGroups = _groups, SimilarSelection = Action == PhotoSimilarAction.Ungroup ? [] : Selected };
    }
    internal bool CanCleanup => Action == PhotoSimilarAction.Cleanup && Selected.Length > 0 && Selected.Length < _groups[0].Group.Count;
    private void RenderSelection() => _selection.Text = _l.Format("PhotosSimilarSelected", _selected.Count);
    private void Render()
    {
        _rendering = true;
        try
        {
            var rows = _groups.SelectMany(detail => detail.Photos.Select(photo => new Row(photo,
                photo.Id.ItemId == detail.Group.TopPickId ? _l.Format("PhotosSimilarBestRow", photo.Filename) : photo.Filename)))
                .Where(row => row.Photo.Filename.Contains(_search.Text, StringComparison.CurrentCultureIgnoreCase)).ToArray();
            _list.ItemsSource = rows; foreach (var row in rows.Where(row => _selected.Contains(row.Photo.Id.ItemId))) _list.SelectedItems.Add(row);
            _empty.Text = rows.Length == 0 ? _l.Get("PhotosSimilarNoMatches") : ""; _empty.Visibility = rows.Length == 0 ? Visibility.Visible : Visibility.Collapsed; RenderSelection();
        }
        finally { _rendering = false; }
        Changed?.Invoke();
    }
}
