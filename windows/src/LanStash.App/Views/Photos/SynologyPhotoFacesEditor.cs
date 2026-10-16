using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace LanStash.App.Views.Photos;

internal sealed class SynologyPhotoFacesEditor : StackPanel
{
    private readonly Localization.LocalizationService _l = Localization.LocalizationService.Current;
    private readonly SynologyPhotoRecognitionKind _kind;
    private readonly SynologyPhotoPerson _source;
    private readonly IReadOnlyList<SynologyPhotoFace> _faces;
    private readonly IReadOnlyList<SynologyPhoto> _photos;
    private readonly Dictionary<long, CheckBox> _checks = [];
    private readonly Dictionary<long, Image> _images = [];
    private readonly ComboBox _target;
    private readonly TextBox _name;
    private readonly TextBlock _selection;
    private sealed record Target(SynologyPhotoPerson? Person, string Title);
    internal event Action? Changed;
    internal SynologyPhotoFacesEditor(SynologyPhotoRecognitionKind kind, SynologyPhotoPerson source, IReadOnlyList<SynologyPhotoPerson> people,
        IReadOnlyList<SynologyPhotoFace> faces, IReadOnlyList<SynologyPhoto> photos)
    {
        _kind = kind; _source = source; _faces = faces; _photos = photos; Spacing = 12;
        var reassign = kind == SynologyPhotoRecognitionKind.ReassignPersonFaces; var cover = kind == SynologyPhotoRecognitionKind.SetPersonCover;
        var choices = new[] { new Target(null, _l.Get("PhotosNewPerson")) }.Concat(people.Where(person => person.Person.Id != source.Person.Id)
            .Select(person => new Target(person, person.Person.Name.Length > 0 ? person.Person.Name : _l.Get("PhotosPersonUnnamed")))).ToArray();
        _target = new ComboBox { Header = _l.Get("PhotosFaceTarget"), HorizontalAlignment = HorizontalAlignment.Stretch, ItemsSource = choices, DisplayMemberPath = nameof(Target.Title), SelectedIndex = 0,
            Visibility = reassign ? Visibility.Visible : Visibility.Collapsed };
        _name = new TextBox { Header = _l.Get("PhotosPersonName"), Visibility = reassign ? Visibility.Visible : Visibility.Collapsed };
        _selection = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var list = new StackPanel { Spacing = 8 };
        foreach (var (face, index) in faces.Select((face, index) => (face, index)))
        {
            var row = new Grid { ColumnSpacing = 12, HorizontalAlignment = HorizontalAlignment.Stretch };
            row.ColumnDefinitions.Add(new() { Width = new GridLength(64) }); row.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
            var image = new Image { Width = 64, Height = 64, Stretch = Stretch.Uniform }; _images[face.Id] = image;
            var title = _l.Format("PhotosFaceChoice", index + 1, face.Photo.Filename);
            AutomationProperties.SetName(image, title); row.Children.Add(image);
            var caption = new TextBlock { Text = title, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center }; Grid.SetColumn(caption, 1); row.Children.Add(caption);
            if (cover) list.Children.Add(row);
            else
            {
                var check = new CheckBox { Content = row, IsChecked = true, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch };
                AutomationProperties.SetName(check, title); _checks[face.Id] = check; check.Checked += (_, _) => Render(); check.Unchecked += (_, _) => Render(); list.Children.Add(check);
            }
        }
        Children.Add(new TextBlock { Text = source.Person.Name.Length > 0 ? source.Person.Name : _l.Get("PhotosPersonUnnamed"), TextWrapping = TextWrapping.Wrap });
        if (cover) Children.Add(new TextBlock { Text = photos[0].Filename, TextWrapping = TextWrapping.Wrap });
        foreach (var control in new FrameworkElement[] { _target, _name, new ScrollViewer { Content = list, MaxHeight = 300 }, _selection }) Children.Add(control);
        _target.SelectionChanged += (_, _) => Render(); _name.TextChanged += (_, _) => Render(); Render();
    }
    internal SynologyPhotoRecognitionEdit? Input()
    {
        if (_faces.Count == 0) return null;
        if (_kind == SynologyPhotoRecognitionKind.SetPersonCover) return new(_kind, [_source]) { Space = _source.Person.Space, CoverPhoto = _photos[0] };
        var selected = _faces.Where(face => _checks[face.Id].IsChecked == true).ToArray(); if (selected.Length == 0) return null;
        var target = (_target.SelectedItem as Target)?.Person;
        var name = target?.Person.Name ?? _name.Text.Trim();
        if (_kind == SynologyPhotoRecognitionKind.ReassignPersonFaces && target is null && name.Length == 0) return null;
        return new(_kind, _kind == SynologyPhotoRecognitionKind.ReassignPersonFaces && target is not null ? [_source, target] : [_source])
        { Space = _source.Person.Space, Faces = selected, Name = _kind == SynologyPhotoRecognitionKind.ReassignPersonFaces ? name : null };
    }
    private void Render()
    {
        _name.Visibility = _kind == SynologyPhotoRecognitionKind.ReassignPersonFaces && (_target.SelectedItem as Target)?.Person is null ? Visibility.Visible : Visibility.Collapsed;
        _selection.Text = _faces.Count == 0 ? _l.Get("PhotosNoPersonFaces") : _kind == SynologyPhotoRecognitionKind.SetPersonCover ? "" : _l.Format("PhotosFacesSelected", _checks.Values.Count(check => check.IsChecked == true));
        _selection.Visibility = _selection.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible; Changed?.Invoke();
    }
    internal async Task LoadImagesAsync(ISynologyPhotosRepository repository, CancellationToken token)
    {
        using var slots = new SemaphoreSlim(4);
        await Task.WhenAll(_faces.Where(face => face.Thumbnail is not null).Select(async face =>
        {
            await slots.WaitAsync(token);
            try { var bytes = await repository.FaceImageAsync(face, token); _images[face.Id].Source = (await SynologyPhotoImages.DecodeAsync(bytes, 160, token)).Value; }
            catch (OperationCanceledException) when (token.IsCancellationRequested) { }
            catch (Exception) { /* 缩略图不可用时保留已读取的人脸与照片标识。 */ }
            finally { slots.Release(); }
        }));
    }
}
