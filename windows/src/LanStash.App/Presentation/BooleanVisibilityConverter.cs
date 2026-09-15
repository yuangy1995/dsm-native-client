using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Data;

namespace LanStash.App.Presentation;

public sealed class BooleanVisibilityConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language) =>
        ((value is true) ^ (parameter is "Not")) ? Visibility.Visible : Visibility.Collapsed;
    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}
