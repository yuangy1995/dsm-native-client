using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views.Photos;

internal sealed class SynologyPhotoPeopleEditor : StackPanel
{
    private readonly Localization.LocalizationService _l = Localization.LocalizationService.Current;
    private readonly SynologyPhotoRecognitionKind _kind;
    private readonly SynologyPhotoSpace _space;
    private readonly SynologyPhotoPerson? _target;
    private readonly IReadOnlyList<SynologyPhotoPerson> _people;
    private readonly TextBox _name, _search;
    private readonly ComboBox _visible;
    private readonly ListView _list;
    private readonly TextBlock _empty, _selection;
    private readonly HashSet<long> _selected = [];
    private bool _rendering;
    internal event Action? Changed;
    private sealed record PersonRow(SynologyPhotoPerson Value, string Title);
    internal SynologyPhotoPeopleEditor(SynologyPhotoRecognitionKind kind, SynologyPhotoSpace space, SynologyPhotoPerson? target, IReadOnlyList<SynologyPhotoPerson> people)
    {
        _kind = kind; _space = space; _target = target; _people = people; Spacing = 12;
        _name = new TextBox { Header = _l.Get("PhotosPersonName"), Text = target?.Person.Name ?? "", Visibility = kind == SynologyPhotoRecognitionKind.ShowPeople ? Visibility.Collapsed : Visibility.Visible };
        _search = new TextBox { Header = _l.Get("PhotosFindPeople"), Visibility = kind == SynologyPhotoRecognitionKind.RenamePerson ? Visibility.Collapsed : Visibility.Visible };
        _visible = new ComboBox { Header = _l.Get("PhotosPeopleSetVisibility"), HorizontalAlignment = HorizontalAlignment.Stretch,
            ItemsSource = new[] { _l.Get("PhotosPeopleShow"), _l.Get("PhotosPeopleHide") }, SelectedIndex = 0,
            Visibility = kind == SynologyPhotoRecognitionKind.ShowPeople ? Visibility.Visible : Visibility.Collapsed };
        _list = new ListView { SelectionMode = ListViewSelectionMode.Multiple, DisplayMemberPath = nameof(PersonRow.Title), MaxHeight = 260,
            Visibility = kind == SynologyPhotoRecognitionKind.RenamePerson ? Visibility.Collapsed : Visibility.Visible };
        AutomationProperties.SetName(_list, _l.Get("PhotosChoosePeople"));
        _empty = new TextBlock { TextWrapping = TextWrapping.Wrap };
        _selection = new TextBlock { TextWrapping = TextWrapping.Wrap, Visibility = _list.Visibility };
        foreach (var control in new FrameworkElement[] { _name, _visible, _search, _list, _empty, _selection }) Children.Add(control);
        _name.TextChanged += (_, _) => Changed?.Invoke(); _search.TextChanged += (_, _) => Render();
        _visible.SelectionChanged += (_, _) => Render();
        _list.SelectionChanged += (_, args) =>
        {
            if (_rendering) return;
            foreach (var item in args.RemovedItems.OfType<PersonRow>()) _selected.Remove(item.Value.Person.Id);
            foreach (var item in args.AddedItems.OfType<PersonRow>()) _selected.Add(item.Value.Person.Id);
            RenderSelection(); Changed?.Invoke();
        };
        Render();
    }
    internal SynologyPhotoRecognitionEdit? Input()
    {
        var people = _kind == SynologyPhotoRecognitionKind.RenamePerson ? _target is null ? [] : new[] { _target } :
            _people.Where(person => _selected.Contains(person.Person.Id) && (_kind != SynologyPhotoRecognitionKind.ShowPeople || person.Visible != (_visible.SelectedIndex == 0))).ToArray();
        if (_kind == SynologyPhotoRecognitionKind.MergePeople && _target is not null) people = new[] { _target }.Concat(people).ToArray();
        if (people.Length == 0 || people.Length > 100 || _kind == SynologyPhotoRecognitionKind.MergePeople && people.Length < 2) return null;
        return new(_kind, people) { Space = _space, Name = _kind == SynologyPhotoRecognitionKind.ShowPeople ? null : _name.Text, Visible = _visible.SelectedIndex == 0 };
    }
    private void RenderSelection()
    {
        var count = _selected.Count + (_kind == SynologyPhotoRecognitionKind.MergePeople ? 1 : 0);
        _selection.Text = count > 100 ? _l.Get("PhotosEditSelectionLimit") : _l.Format("PhotosPeopleSelection", count);
    }
    private void Render()
    {
        _rendering = true;
        try
        {
            var candidates = _people.Where(person => _kind != SynologyPhotoRecognitionKind.MergePeople || person.Person.Id != _target?.Person.Id).ToArray();
            var rows = candidates.Where(person => person.Person.Name.Contains(_search.Text, StringComparison.CurrentCultureIgnoreCase)).Select(person =>
            {
                var name = string.IsNullOrEmpty(person.Person.Name) ? _l.Get("PhotosPersonUnnamed") : person.Person.Name;
                return new PersonRow(person, _kind == SynologyPhotoRecognitionKind.ShowPeople
                    ? _l.Format("PhotosPeopleVisibilityRow", name, _l.Get(person.Visible == true ? "PhotosPersonVisible" : "PhotosPersonHidden")) : name);
            }).ToArray();
            _list.ItemsSource = rows; foreach (var row in rows.Where(row => _selected.Contains(row.Value.Person.Id))) _list.SelectedItems.Add(row);
            _empty.Text = _kind == SynologyPhotoRecognitionKind.RenamePerson || rows.Length > 0 ? "" : _l.Get(candidates.Length == 0 ? "PhotosPeopleEmpty" : "PhotosPeopleNoMatches");
            _empty.Visibility = _empty.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed; RenderSelection();
        }
        finally { _rendering = false; }
        Changed?.Invoke();
    }
}
