using System.Runtime.InteropServices.WindowsRuntime;
using LanStash.App.Features.Photos.Synology;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Foundation;

namespace LanStash.App.Views.Photos;

internal sealed class SynologyPhotoManualFacesEditor : Grid
{
    private readonly Localization.LocalizationService _l = Localization.LocalizationService.Current;
    private readonly SynologyPhoto _photo;
    private readonly SynologyPhotoFaceImage _image;
    private readonly IReadOnlyList<SynologyPhotoFaceRegion> _originals;
    private readonly IReadOnlyList<SynologyPhotoCollection> _people;
    private readonly List<SynologyPhotoFaceDraft> _drafts;
    private readonly Grid _picture = new() { Height = 360, MinWidth = 180 };
    private readonly Canvas _canvas = new() { Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    private readonly Image _bitmap = new() { Stretch = Stretch.Fill, IsHitTestVisible = false };
    private readonly StackPanel _inspector = new() { Spacing = 10, MinWidth = 230 };
    private readonly ComboBox _face, _target;
    private readonly TextBox _name;
    private readonly NumberBox _x, _y, _size;
    private readonly Button _add, _remove;
    private readonly TextBlock _empty, _count;
    private int _selected = -1;
    private bool _rendering, _dragging, _resizing, _drawing, _moved;
    private bool? _wide;
    private uint? _pointerId;
    private Point _start;
    private SynologyPhotoFaceBounds? _startBounds, _drawingBounds;
    private sealed record Choice(string Id, string Title);
    private sealed record PersonChoice(SynologyPhotoCollection? Person, string Title);
    internal event Action? Changed;
    internal IReadOnlyList<SynologyPhotoFaceDraft> Drafts => _drafts;
    internal bool CanSave => _drafts.Any(SynologyPhotoFaceEditing.IsChanged) && _drafts.All(draft => SynologyPhotoFaceEditing.IsValid(draft, _people)) &&
        _drafts.Sum(draft => !SynologyPhotoFaceEditing.IsChanged(draft) ? 0 : draft.Original is not null && !draft.Removed && draft.Bounds != draft.Original.Bounds ? 2 : 1) <= 100;
    internal SynologyPhotoManualFacesEditor(SynologyPhoto photo, SynologyPhotoFaceImage image, IReadOnlyList<SynologyPhotoFaceRegion> originals, IReadOnlyList<SynologyPhotoPerson> people)
    {
        _photo = photo; _image = image; _originals = originals.ToArray(); ColumnSpacing = 16; RowSpacing = 12;
        _people = people.Select(person => person.Person).Concat(originals.Where(face => face.PersonId > 0 && !people.Any(person => person.Person.Id == face.PersonId))
            .Select(face => new SynologyPhotoCollection(face.PersonId, face.Name) { Space = photo.Id.Space })).DistinctBy(person => person.Id).ToArray();
        _drafts = originals.Select(face => new SynologyPhotoFaceDraft(Guid.NewGuid().ToString("N"), face, face.Bounds, face.PersonId, face.Name)).ToList();
        _face = new ComboBox { Header = _l.Get("PhotosManualSelectedFace"), HorizontalAlignment = HorizontalAlignment.Stretch, DisplayMemberPath = nameof(Choice.Title) };
        _target = new ComboBox { Header = _l.Get("PhotosFaceTarget"), HorizontalAlignment = HorizontalAlignment.Stretch, DisplayMemberPath = nameof(PersonChoice.Title),
            ItemsSource = new[] { new PersonChoice(null, _l.Get("PhotosNewPerson")) }.Concat(_people.Select(person => new PersonChoice(person, PersonName(person.Name)))).ToArray() };
        _name = new TextBox { Header = _l.Get("PhotosPersonName") };
        _x = Number("PhotosManualX"); _y = Number("PhotosManualY"); _size = Number("PhotosManualSize");
        _add = Button("PhotosManualAdd"); _remove = Button("PhotosManualRemove");
        _empty = new TextBlock { Text = _l.Get("PhotosManualEmpty"), TextWrapping = TextWrapping.Wrap };
        _count = new TextBlock { TextWrapping = TextWrapping.Wrap };
        foreach (var element in new FrameworkElement[] { _add, _empty, _face, _target, _name, _x, _y, _size, _remove, _count }) _inspector.Children.Add(element);
        _canvas.Children.Add(_bitmap); _picture.Children.Add(_canvas); Children.Add(_picture); Children.Add(_inspector);
        AutomationProperties.SetName(_canvas, _l.Get("PhotosManualCanvas")); AutomationProperties.SetHelpText(_canvas, _l.Get("PhotosManualCanvasHelp"));
        _picture.SizeChanged += (_, _) => Fit(); SizeChanged += (_, _) => Layout();
        _canvas.PointerPressed += Pressed; _canvas.PointerMoved += Moved; _canvas.PointerReleased += Released;
        _canvas.PointerCanceled += (_, args) => { if (_pointerId == args.Pointer.PointerId) CancelPointer(); };
        _canvas.PointerCaptureLost += (_, args) => { if (_pointerId == args.Pointer.PointerId) CancelPointer(); };
        _add.Click += (_, _) => AddFace(SynologyPhotoFaceEditing.Center(_image.Width, _image.Height));
        _remove.Click += (_, _) =>
        {
            if (_selected < 0) return; var draft = _drafts[_selected];
            if (draft.Original is null) { _drafts.RemoveAt(_selected); _selected = Math.Min(_selected, _drafts.Count - 1); }
            else _drafts[_selected] = draft with { Removed = !draft.Removed }; Render();
        };
        _face.SelectionChanged += (_, _) => { if (_rendering || _face.SelectedItem is not Choice item) return; _selected = _drafts.FindIndex(draft => draft.Id == item.Id); Render(); };
        _target.SelectionChanged += (_, _) =>
        {
            if (_rendering || _selected < 0 || _target.SelectedItem is not PersonChoice item) return; var draft = _drafts[_selected];
            _drafts[_selected] = draft with { PersonId = item.Person?.Id ?? 0, Name = item.Person?.Name ?? "" }; Render();
        };
        _name.TextChanged += (_, _) => { if (_rendering || _selected < 0) return; _drafts[_selected] = _drafts[_selected] with { Name = _name.Text }; Render(); };
        _x.ValueChanged += (_, _) => AdjustNumber(0); _y.ValueChanged += (_, _) => AdjustNumber(1); _size.ValueChanged += (_, _) => AdjustNumber(2);
        _selected = _drafts.Count == 0 ? -1 : 0; Layout(); Render();
    }
    private NumberBox Number(string key) => new() { Header = _l.Get(key), Minimum = 0, SmallChange = 1, LargeChange = 10,
        SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact, HorizontalAlignment = HorizontalAlignment.Stretch };
    private Button Button(string key) => new() { Content = _l.Get(key), HorizontalAlignment = HorizontalAlignment.Stretch, MinHeight = 36 };
    private string PersonName(string value) => value.Length == 0 ? _l.Get("PhotosPersonUnnamed") : value;
    private void Layout()
    {
        var wide = ActualWidth >= 640; if (_wide == wide) return; _wide = wide; ColumnDefinitions.Clear(); RowDefinitions.Clear();
        ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        if (wide) ColumnDefinitions.Add(new() { Width = new GridLength(260) });
        RowDefinitions.Add(new() { Height = GridLength.Auto }); if (!wide) RowDefinitions.Add(new() { Height = GridLength.Auto });
        Grid.SetColumn(_inspector, wide ? 1 : 0); Grid.SetRow(_inspector, wide ? 0 : 1); _picture.Height = wide ? 440 : 280;
    }
    private void Fit()
    {
        if (_picture.ActualWidth <= 0 || _picture.ActualHeight <= 0) return;
        var scale = Math.Min(_picture.ActualWidth / _image.Width, _picture.ActualHeight / _image.Height);
        _canvas.Width = _bitmap.Width = _image.Width * scale; _canvas.Height = _bitmap.Height = _image.Height * scale; Draw();
    }
    internal async Task LoadImageAsync(CancellationToken token)
    {
        var bitmap = new WriteableBitmap(_image.Width, _image.Height);
        using (var stream = bitmap.PixelBuffer.AsStream()) await stream.WriteAsync(_image.Pixels, token);
        bitmap.Invalidate(); _bitmap.Source = bitmap;
    }
    internal void AddFace(SynologyPhotoFaceBounds bounds)
    {
        if (_drafts.Count(draft => !draft.Removed) >= 100) return;
        _drafts.Add(new(Guid.NewGuid().ToString("N"), null, bounds, 0, "")); _selected = _drafts.Count - 1; Render();
    }
    private void AdjustNumber(int part)
    {
        if (_rendering || _selected < 0 || !double.IsFinite(_x.Value) || !double.IsFinite(_y.Value) || !double.IsFinite(_size.Value)) return;
        var draft = _drafts[_selected]; var bounds = draft.Bounds;
        if (part == 0) bounds = bounds with { X = Math.Clamp(_x.Value / _image.Width, 0, 1 - bounds.Width) };
        if (part == 1) bounds = bounds with { Y = Math.Clamp(_y.Value / _image.Height, 0, 1 - bounds.Height) };
        if (part == 2) bounds = SynologyPhotoFaceEditing.Resize(bounds, bounds.X * _image.Width + _size.Value, bounds.Y * _image.Height + _size.Value, _image.Width, _image.Height, 1);
        _drafts[_selected] = draft with { Bounds = bounds }; Render();
    }
    private void Render()
    {
        _rendering = true;
        try
        {
            _face.ItemsSource = _drafts.Select((draft, index) => new Choice(draft.Id, _l.Format(draft.Removed ? "PhotosManualRemovedChoice" : "PhotosManualFaceChoice", index + 1, PersonName(draft.Name)))).ToArray();
            _face.SelectedIndex = _selected; _face.Visibility = _drafts.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
            _empty.Visibility = _drafts.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
            var selected = _selected >= 0 ? _drafts[_selected] : null;
            foreach (var element in new FrameworkElement[] { _target, _name, _x, _y, _size, _remove }) element.Visibility = selected is null ? Visibility.Collapsed : Visibility.Visible;
            if (selected is not null)
            {
                _target.SelectedIndex = selected.PersonId == 0 ? 0 : Math.Max(0, _people.ToList().FindIndex(person => person.Id == selected.PersonId) + 1);
                _name.Text = selected.Name; _name.Visibility = selected.PersonId == 0 ? Visibility.Visible : Visibility.Collapsed;
                _x.Maximum = (1 - selected.Bounds.Width) * _image.Width; _y.Maximum = (1 - selected.Bounds.Height) * _image.Height;
                _size.Minimum = 1; _size.Maximum = Math.Max(selected.Bounds.Width * _image.Width, Math.Max(1, Math.Min((1 - selected.Bounds.X) * _image.Width, (1 - selected.Bounds.Y) * _image.Height)));
                _x.Value = Math.Round(selected.Bounds.X * _image.Width, 3); _y.Value = Math.Round(selected.Bounds.Y * _image.Height, 3); _size.Value = Math.Round(selected.Bounds.Width * _image.Width, 3);
                _target.IsEnabled = _name.IsEnabled = _x.IsEnabled = _y.IsEnabled = _size.IsEnabled = !selected.Removed;
                _remove.Content = _l.Get(selected.Removed ? "PhotosManualUndoRemove" : "PhotosManualRemove");
            }
            _add.IsEnabled = _drafts.Count(draft => !draft.Removed) < 100; var count = _drafts.Count(SynologyPhotoFaceEditing.IsChanged);
            _count.Text = count > 0 ? _l.Format("PhotosManualChangedCount", count) : ""; _count.Visibility = count > 0 ? Visibility.Visible : Visibility.Collapsed;
            Draw();
        }
        finally { _rendering = false; }
        Changed?.Invoke();
    }
    private void Draw()
    {
        if (!double.IsFinite(_canvas.Width) || !double.IsFinite(_canvas.Height) || _canvas.Width <= 0 || _canvas.Height <= 0) return;
        while (_canvas.Children.Count > 1) _canvas.Children.RemoveAt(1);
        foreach (var (draft, index) in _drafts.Select((draft, index) => (draft, index)))
        {
            var rectangle = new Border { BorderThickness = new(index == _selected ? 3 : 2), IsHitTestVisible = false,
                BorderBrush = new SolidColorBrush(draft.Removed ? Microsoft.UI.Colors.Gray : index == _selected ? Microsoft.UI.Colors.DeepSkyBlue : Microsoft.UI.Colors.White),
                Opacity = draft.Removed ? 0.45 : 1, Child = new Border { Background = new SolidColorBrush(Windows.UI.Color.FromArgb(180, 0, 0, 0)), HorizontalAlignment = HorizontalAlignment.Left,
                    VerticalAlignment = VerticalAlignment.Top, Child = new TextBlock { Text = (index + 1).ToString(System.Globalization.CultureInfo.CurrentCulture),
                    Foreground = new SolidColorBrush(Microsoft.UI.Colors.White), FontWeight = Microsoft.UI.Text.FontWeights.Bold, Margin = new(4) } } };
            Place(rectangle, draft.Bounds); _canvas.Children.Add(rectangle);
            if (index == _selected && !draft.Removed)
            {
                var handle = new Border { Width = 18, Height = 18, Background = new SolidColorBrush(Microsoft.UI.Colors.DeepSkyBlue), IsHitTestVisible = false };
                Canvas.SetLeft(handle, (draft.Bounds.X + draft.Bounds.Width) * _canvas.Width - 18); Canvas.SetTop(handle, (draft.Bounds.Y + draft.Bounds.Height) * _canvas.Height - 18); _canvas.Children.Add(handle);
            }
        }
        if (_drawingBounds is { } drawing) { var rectangle = new Border { BorderThickness = new(2), BorderBrush = new SolidColorBrush(Microsoft.UI.Colors.DeepSkyBlue), IsHitTestVisible = false }; Place(rectangle, drawing); _canvas.Children.Add(rectangle); }
    }
    private void Place(FrameworkElement element, SynologyPhotoFaceBounds bounds)
    { element.Width = bounds.Width * _canvas.Width; element.Height = bounds.Height * _canvas.Height; Canvas.SetLeft(element, bounds.X * _canvas.Width); Canvas.SetTop(element, bounds.Y * _canvas.Height); }
    private void Pressed(object sender, PointerRoutedEventArgs args)
    {
        var point = args.GetCurrentPoint(_canvas);
        if (_pointerId is not null || !args.Pointer.IsInContact || args.Pointer.PointerDeviceType == Microsoft.UI.Input.PointerDeviceType.Mouse && !point.Properties.IsLeftButtonPressed || _canvas.Width <= 0 || _canvas.Height <= 0) return;
        _start = point.Position; _moved = false; _selected = _drafts.FindLastIndex(draft => _start.X >= draft.Bounds.X * _canvas.Width && _start.X <= (draft.Bounds.X + draft.Bounds.Width) * _canvas.Width &&
            _start.Y >= draft.Bounds.Y * _canvas.Height && _start.Y <= (draft.Bounds.Y + draft.Bounds.Height) * _canvas.Height);
        _drawing = _selected < 0; _dragging = _selected >= 0 && !_drafts[_selected].Removed; _startBounds = _selected >= 0 ? _drafts[_selected].Bounds : null;
        _resizing = _startBounds is { } box && _start.X >= (box.X + box.Width) * _canvas.Width - 20 && _start.Y >= (box.Y + box.Height) * _canvas.Height - 20;
        if (!_canvas.CapturePointer(args.Pointer)) { CancelPointer(); return; }
        _pointerId = args.Pointer.PointerId; args.Handled = true; Render();
    }
    private void Moved(object sender, PointerRoutedEventArgs args)
    {
        if (_pointerId != args.Pointer.PointerId || !_drawing && !_dragging) return; var point = args.GetCurrentPoint(_canvas).Position;
        if (Math.Abs(point.X - _start.X) + Math.Abs(point.Y - _start.Y) < 1) return; _moved = true;
        if (_drawing) { _drawingBounds = SynologyPhotoFaceEditing.Square(_start.X, _start.Y, point.X, point.Y, _canvas.Width, _canvas.Height); Draw(); }
        else if (_startBounds is { } box)
        { _drafts[_selected] = _drafts[_selected] with { Bounds = _resizing ? SynologyPhotoFaceEditing.Resize(box, point.X, point.Y, _canvas.Width, _canvas.Height) :
            SynologyPhotoFaceEditing.Move(box, point.X - _start.X, point.Y - _start.Y, _canvas.Width, _canvas.Height) }; Render(); }
        args.Handled = true;
    }
    private void Released(object sender, PointerRoutedEventArgs args)
    {
        if (_pointerId != args.Pointer.PointerId) return;
        if (_drawing && _moved && _drawingBounds is { } bounds) AddFace(bounds);
        _drawing = _dragging = false; _drawingBounds = null; _pointerId = null; _canvas.ReleasePointerCapture(args.Pointer); args.Handled = true; Draw();
    }
    private void CancelPointer() { _drawing = _dragging = false; _drawingBounds = null; _pointerId = null; Draw(); }
    internal Task<SynologyPhotoRecognitionEdit> InputAsync(CancellationToken token = default) => SynologyPhotoFaceEditing.EditAsync(_photo, _image, _originals, _drafts.ToArray(), _people, token);
}
