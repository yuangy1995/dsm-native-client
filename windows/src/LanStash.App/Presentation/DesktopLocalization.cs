using LanStash.App.Localization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace LanStash.App.Presentation;

/// <summary>重用既有 resw；更新已实例化的控件，不重建会话、传输或编辑器。</summary>
public static class DesktopLocalization
{
    public static readonly DependencyProperty BindingsProperty = DependencyProperty.RegisterAttached(
        "Bindings", typeof(string), typeof(DesktopLocalization), new PropertyMetadata("", BindingsChanged));

    public static string GetBindings(DependencyObject target) => (string)target.GetValue(BindingsProperty);
    public static void SetBindings(DependencyObject target, string value) => target.SetValue(BindingsProperty, value);

    private static void BindingsChanged(DependencyObject target, DependencyPropertyChangedEventArgs args)
    {
        if (target is not FrameworkElement element) return;
        element.Loaded -= ElementLoaded;
        element.Loaded += ElementLoaded;
        if (element.IsLoaded) Apply(element);
    }

    private static void ElementLoaded(object sender, RoutedEventArgs args) => Apply((FrameworkElement)sender);

    public static void RefreshTree(DependencyObject root)
    {
        var pending = new Stack<DependencyObject>();
        pending.Push(root);
        while (pending.TryPop(out var current))
        {
            if (current is FrameworkElement element) Apply(element);
            for (var i = 0; i < VisualTreeHelper.GetChildrenCount(current); i++)
                pending.Push(VisualTreeHelper.GetChild(current, i));
        }
    }

    private static void Apply(FrameworkElement element)
    {
        foreach (var binding in GetBindings(element).Split(';', StringSplitOptions.RemoveEmptyEntries))
        {
            var separator = binding.IndexOf('=');
            if (separator <= 0) continue;
            var property = binding[..separator];
            var text = LocalizationService.Current.Get(binding[(separator + 1)..]);
            switch (property)
            {
                case "Text" when element is TextBlock block: block.Text = text; break;
                case "Text" when element is MenuFlyoutItem item: item.Text = text; break;
                case "Content" when element is ContentControl content: content.Content = text; break;
                case "Label" when element is AppBarButton button: button.Label = text; break;
                case "Label" when element is AppBarToggleButton toggle: toggle.Label = text; break;
                case "Label" when element is Button button && button.Content is string: button.Content = text; break;
                case "Header" when element is TextBox box: box.Header = text; break;
                case "Header" when element is PasswordBox box: box.Header = text; break;
                case "Header" when element is ComboBox box: box.Header = text; break;
                case "Header" when element is ToggleSwitch toggle: toggle.Header = text; break;
                case "Header" when element is Expander expander: expander.Header = text; break;
                case "Header" when element is PivotItem pivot: pivot.Header = text; break;
                case "PlaceholderText" when element is TextBox box: box.PlaceholderText = text; break;
                case "PlaceholderText" when element is AutoSuggestBox box: box.PlaceholderText = text; break;
                case "Description" when element is TextBox box: box.Description = text; break;
                case "Title" when element is InfoBar bar: bar.Title = text; break;
                case "Message" when element is InfoBar bar: bar.Message = text; break;
                case "OnContent" when element is ToggleSwitch toggle: toggle.OnContent = text; break;
                case "OffContent" when element is ToggleSwitch toggle: toggle.OffContent = text; break;
                case "AutomationProperties.Name": AutomationProperties.SetName(element, text); break;
                case "ToolTipService.ToolTip": ToolTipService.SetToolTip(element, text); break;
                case "AccessKey": element.AccessKey = text; break;
            }
        }
    }
}
