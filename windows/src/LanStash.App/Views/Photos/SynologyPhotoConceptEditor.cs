using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views.Photos;

internal sealed class SynologyPhotoConceptEditor : StackPanel
{
    private readonly Localization.LocalizationService _l = Localization.LocalizationService.Current;
    private readonly SynologyPhotoRecognitionKind _kind;
    private readonly SynologyPhotoSpace _space;
    private readonly IReadOnlyList<SynologyPhotoConcept> _concepts;
    private readonly IReadOnlyList<SynologyPhoto> _photos;
    private readonly TextBox _search;
    private readonly ComboBox _visible;
    private readonly ListView _list;
    private readonly TextBlock _empty, _selection;
    private readonly HashSet<long> _selected = [];
    private bool _rendering;
    internal event Action? Changed;
    private sealed record ConceptRow(SynologyPhotoConcept Value, string Title);
    internal SynologyPhotoConceptEditor(SynologyPhotoRecognitionKind kind, SynologyPhotoSpace space, IReadOnlyList<SynologyPhotoConcept> concepts, IReadOnlyList<SynologyPhoto> photos)
    {
        _kind = kind; _space = space; _concepts = concepts; _photos = photos; Spacing = 12;
        var display = kind == SynologyPhotoRecognitionKind.ShowConcepts;
        _search = new TextBox { Header = _l.Get("PhotosFindConcepts"), Visibility = display ? Visibility.Visible : Visibility.Collapsed };
        _visible = new ComboBox { Header = _l.Get("PhotosPeopleSetVisibility"), HorizontalAlignment = HorizontalAlignment.Stretch,
            ItemsSource = new[] { _l.Get("PhotosConceptShow"), _l.Get("PhotosConceptHide") }, SelectedIndex = 0, Visibility = _search.Visibility };
        _list = new ListView { SelectionMode = ListViewSelectionMode.Multiple, DisplayMemberPath = nameof(ConceptRow.Title), MaxHeight = 280, Visibility = _search.Visibility };
        AutomationProperties.SetName(_list, _l.Get("PhotosChooseConcepts"));
        _empty = new TextBlock { TextWrapping = TextWrapping.Wrap }; _selection = new TextBlock { TextWrapping = TextWrapping.Wrap, Visibility = _search.Visibility };
        foreach (var control in new FrameworkElement[] { _visible, _search, _list, _empty, _selection }) Children.Add(control);
        if (!display)
        {
            Children.Add(new TextBlock { Text = concepts.Single().Concept.Name, TextWrapping = TextWrapping.Wrap, FontSize = 18 });
            foreach (var photo in photos) Children.Add(new TextBlock { Text = photo.Filename, TextWrapping = TextWrapping.Wrap });
        }
        _search.TextChanged += (_, _) => Render(); _visible.SelectionChanged += (_, _) => Render();
        _list.SelectionChanged += (_, args) =>
        {
            if (_rendering) return;
            foreach (var row in args.RemovedItems.OfType<ConceptRow>()) _selected.Remove(row.Value.Concept.Id);
            foreach (var row in args.AddedItems.OfType<ConceptRow>()) _selected.Add(row.Value.Concept.Id);
            RenderSelection(); Changed?.Invoke();
        };
        Render();
    }
    internal SynologyPhotoRecognitionEdit? Input()
    {
        var values = _kind == SynologyPhotoRecognitionKind.ShowConcepts ? _concepts.Where(value => _selected.Contains(value.Concept.Id) && value.Visible != (_visible.SelectedIndex == 0)).ToArray() : _concepts.ToArray();
        if (values.Length is 0 or > 100 || _kind != SynologyPhotoRecognitionKind.ShowConcepts && (_photos.Count is 0 or > 100 || values.Length != 1) ||
            _kind == SynologyPhotoRecognitionKind.SetConceptCover && _photos.Count != 1 ||
            _kind == SynologyPhotoRecognitionKind.RemoveConceptPhotos && (values[0].Concept.Count is not { } count || count < _photos.Count || values[0].DisplayThreshold is null)) return null;
        return new(_kind, []) { Space = _space, Concepts = values, ConceptPhotos = _photos.ToArray(), Visible = _visible.SelectedIndex == 0 };
    }
    private void RenderSelection() => _selection.Text = _selected.Count > 100 ? _l.Get("PhotosEditSelectionLimit") : _l.Format("PhotosConceptSelection", _selected.Count);
    private void Render()
    {
        _rendering = true;
        try
        {
            var rows = _concepts.Where(value => value.Concept.Name.Contains(_search.Text, StringComparison.CurrentCultureIgnoreCase)).Select(value =>
                new ConceptRow(value, _l.Format("PhotosPeopleVisibilityRow", value.Concept.Name, _l.Get(value.AppearsInList ? "PhotosPersonVisible" : "PhotosPersonHidden")))).ToArray();
            _list.ItemsSource = rows; foreach (var row in rows.Where(row => _selected.Contains(row.Value.Concept.Id))) _list.SelectedItems.Add(row);
            _empty.Text = _kind != SynologyPhotoRecognitionKind.ShowConcepts || rows.Length > 0 ? "" : _l.Get(_concepts.Count == 0 ? "PhotosConceptsEmpty" : "PhotosConceptsNoMatches");
            _empty.Visibility = _empty.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed; RenderSelection();
        }
        finally { _rendering = false; }
        Changed?.Invoke();
    }
}
