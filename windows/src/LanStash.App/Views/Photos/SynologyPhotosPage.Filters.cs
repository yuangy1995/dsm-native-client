using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views.Photos;

public sealed partial class SynologyPhotosPage
{
    private async void Filters_Click(object sender, RoutedEventArgs args)
    {
        if (_disposed || _dialog is not null || _model.Deletion.IsBusy) return;
        var generation = _viewGeneration;
        var dialog = new SynologyPhotoFilterDialog(_model) { XamlRoot = XamlRoot };
        try
        {
            _dialog = dialog;
            var result = await dialog.ShowAsync();
            if (!_disposed && generation == _viewGeneration && result != ContentDialogResult.None && dialog.Result is { } filter)
                await _model.ApplyFilterAsync(filter);
        }
        finally { if (ReferenceEquals(_dialog, dialog)) _dialog = null; }
    }
}
