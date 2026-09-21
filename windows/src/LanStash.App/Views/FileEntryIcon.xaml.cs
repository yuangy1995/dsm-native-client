using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

// 使用矢量图，避免不同系统字体版本将文件夹码位显示成其他图案。
public sealed partial class FileEntryIcon : UserControl
{
    public static readonly DependencyProperty IsDirectoryProperty = DependencyProperty.Register(
        nameof(IsDirectory), typeof(bool), typeof(FileEntryIcon),
        new PropertyMetadata(false, (sender, _) => ((FileEntryIcon)sender).UpdateVisual()));

    public bool IsDirectory
    {
        get => (bool)GetValue(IsDirectoryProperty);
        set => SetValue(IsDirectoryProperty, value);
    }

    public FileEntryIcon()
    {
        InitializeComponent();
        UpdateVisual();
    }

    private void UpdateVisual()
    {
        if (FolderVisual is null) return;
        FolderVisual.Visibility = IsDirectory ? Visibility.Visible : Visibility.Collapsed;
        DocumentVisual.Visibility = IsDirectory ? Visibility.Collapsed : Visibility.Visible;
    }
}
