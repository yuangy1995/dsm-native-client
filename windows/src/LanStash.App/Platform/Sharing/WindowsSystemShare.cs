using Microsoft.UI.Xaml;

namespace LanStash.App.Platform.Sharing;

internal sealed class WindowsSystemShare
{
    private readonly Func<Window?> _window;

    public WindowsSystemShare(Func<Window?> window)
    {
        _window = window;
    }

    // 当前工程明确使用 WindowsPackageType=None。未经打包身份实机验证前，不注册
    // DataTransferManagerInterop 事件，避免在错误窗口或不支持的运行环境暴露入口。
    public bool IsAvailable => false;

    public bool TryShow(Uri value)
    {
        ArgumentNullException.ThrowIfNull(value);
        _ = _window();
        return false;
    }
}
