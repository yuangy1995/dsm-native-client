using System.ComponentModel;
using System.Globalization;
using System.Runtime.InteropServices;

namespace LanStash.App;

internal sealed class TrayIcon : IDisposable
{
    private const uint CallbackMessage = 0x8001;
    private const uint SelectMessage = 0x0400;
    private const uint KeySelectMessage = 0x0401;
    private const uint LeftButtonUpMessage = 0x0202;
    private const uint LeftButtonDoubleClickMessage = 0x0203;
    private const uint RightButtonUpMessage = 0x0205;
    private const uint ContextMenuMessage = 0x007B;
    private const int OpenCommand = 1;
    private const int ToggleMappingsCommand = 2;
    private const int ShowIssuesCommand = 3;
    private const int ExitCommand = 4;
    private const int WindowProcedureIndex = -4;

    private readonly nint _windowHandle;
    private readonly nint _iconHandle;
    private readonly Action _showWindow;
    private readonly Action _toggleMappings;
    private readonly Action _showIssues;
    private readonly Action _exitApplication;
    private readonly Func<int> _mappingCount;
    private readonly Func<bool> _allMappingsPaused;
    private readonly Func<int> _issueCount;
    private readonly WindowProcedure _windowProcedure;
    private readonly NotifyIcon _notifyIcon;
    private readonly uint _taskbarCreatedMessage;
    private nint _previousWindowProcedure;
    private string _openText;
    private string _pauseText;
    private string _resumeText;
    private string _issuesText;
    private string _exitText;
    private string _tooltip;
    private bool _usesVersion4;
    private bool _registered;
    private bool _disposed;

    public TrayIcon(
        nint windowHandle,
        string iconPath,
        string tooltip,
        string openText,
        string pauseText,
        string resumeText,
        string issuesText,
        string exitText,
        Func<int> mappingCount,
        Func<bool> allMappingsPaused,
        Func<int> issueCount,
        Action showWindow,
        Action toggleMappings,
        Action showIssues,
        Action exitApplication,
        NotifyIcon? notifyIcon = null)
    {
        _windowHandle = windowHandle;
        _showWindow = showWindow;
        _toggleMappings = toggleMappings;
        _showIssues = showIssues;
        _exitApplication = exitApplication;
        _notifyIcon = notifyIcon ?? ShellNotifyIcon;
        _mappingCount = mappingCount;
        _allMappingsPaused = allMappingsPaused;
        _issueCount = issueCount;
        _openText = openText;
        _pauseText = pauseText;
        _resumeText = resumeText;
        _issuesText = issuesText;
        _exitText = exitText;
        _tooltip = tooltip;
        _taskbarCreatedMessage = RegisterWindowMessage("TaskbarCreated");
        if (_taskbarCreatedMessage == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
        _windowProcedure = HandleWindowMessage;
        Marshal.SetLastPInvokeError(0);
        _previousWindowProcedure = SetWindowLongPtr(
            _windowHandle,
            WindowProcedureIndex,
            Marshal.GetFunctionPointerForDelegate(_windowProcedure));
        var windowProcedureError = Marshal.GetLastPInvokeError();
        if (_previousWindowProcedure == 0 && windowProcedureError != 0)
        {
            throw new Win32Exception(windowProcedureError);
        }

        _iconHandle = LoadImage(
            0,
            iconPath,
            1,
            0,
            0,
            0x0010 | 0x0040);
        if (_iconHandle == 0)
        {
            RestoreWindowProcedure();
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }

        // Shell 暂时不可用不阻止主窗口启动；关闭时必须仍保留可达入口。
        EnsureRegistered();
    }

    internal bool EnsureRegistered()
    {
        if (_disposed) return false;
        if (_registered) return true;
        var data = CreateData(_tooltip);
        _registered = _notifyIcon(0, ref data);
        _usesVersion4 = false;
        if (_registered)
        {
            data.TimeoutOrVersion = 4;
            _usesVersion4 = _notifyIcon(4, ref data);
        }
        return _registered;
    }

    public void UpdateText(
        string tooltip,
        string openText,
        string pauseText,
        string resumeText,
        string issuesText,
        string exitText)
    {
        if (_disposed) return;
        _tooltip = tooltip;
        _openText = openText;
        _pauseText = pauseText;
        _resumeText = resumeText;
        _issuesText = issuesText;
        _exitText = exitText;
        var data = CreateData(tooltip);
        _registered = _notifyIcon(1, ref data);
        if (!_registered && !EnsureRegistered()) _showWindow();
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
        _registered = false;
        var data = CreateData(string.Empty);
        _ = _notifyIcon(2, ref data);
        if (_iconHandle != 0)
        {
            DestroyIcon(_iconHandle);
        }
        RestoreWindowProcedure();
        GC.SuppressFinalize(this);
    }

    private NotificationIconData CreateData(string tooltip) =>
        new()
        {
            Size = (uint)Marshal.SizeOf<NotificationIconData>(),
            WindowHandle = _windowHandle,
            Id = 1,
            Flags = 0x0001 | 0x0002 | 0x0004 | 0x0080,
            CallbackMessage = CallbackMessage,
            IconHandle = _iconHandle,
            Tooltip = tooltip.Length > 127 ? tooltip[..127] : tooltip,
            Info = string.Empty,
            InfoTitle = string.Empty,
        };

    private nint HandleWindowMessage(
        nint windowHandle,
        uint message,
        nint wordParameter,
        nint longParameter)
    {
        if (!_disposed && message == _taskbarCreatedMessage)
        {
            _registered = false;
            // 广播也可能来自主显示器 DPI 变化；已有图标先尝试更新，缺失时重新添加。
            var data = CreateData(_tooltip);
            _registered = _notifyIcon(1, ref data);
            if (!_registered && !EnsureRegistered()) _showWindow();
        }
        else if (!_disposed && message == CallbackMessage &&
            (_usesVersion4 ? unchecked((uint)(longParameter.ToInt64() >> 16)) & 0xFFFF : unchecked((uint)wordParameter.ToInt64())) == 1)
        {
            var mouseMessage = unchecked((uint)(longParameter.ToInt64() & 0xFFFF));
            if (mouseMessage is LeftButtonUpMessage or LeftButtonDoubleClickMessage or SelectMessage or KeySelectMessage)
            {
                _showWindow();
                return 0;
            }
            if (mouseMessage is RightButtonUpMessage or ContextMenuMessage)
            {
                ShowContextMenu();
                return 0;
            }
        }
        // 本菜单使用 TPM_RETURNCMD；其他窗口控件的 WM_COMMAND 不属于托盘。
        return CallWindowProc(
            _previousWindowProcedure,
            windowHandle,
            message,
            wordParameter,
            longParameter);
    }

    private void ShowContextMenu()
    {
        var menu = CreatePopupMenu();
        if (menu == 0)
        {
            return;
        }
        try
        {
            _ = AppendMenu(menu, 0, OpenCommand, _openText);
            var mappingCount = _mappingCount();
            _ = AppendMenu(
                menu,
                mappingCount == 0 ? 0x0001u : 0,
                ToggleMappingsCommand,
                _allMappingsPaused() ? _resumeText : _pauseText);
            var issueCount = _issueCount();
            _ = AppendMenu(
                menu,
                issueCount == 0 ? 0x0001u : 0,
                ShowIssuesCommand,
                string.Format(
                    CultureInfo.CurrentCulture,
                    _issuesText,
                    issueCount));
            _ = AppendMenu(menu, 0x0800, 0, null);
            _ = AppendMenu(menu, 0, ExitCommand, _exitText);
            _ = GetCursorPos(out var position);
            _ = SetForegroundWindow(_windowHandle);
            var command = TrackPopupMenu(
                menu,
                0x0002 | 0x0100,
                position.X,
                position.Y,
                0,
                _windowHandle,
                0);
            HandleCommand(command);
        }
        finally
        {
            DestroyMenu(menu);
        }
    }

    private void HandleCommand(int command)
    {
        if (_disposed) return;
        switch (command)
        {
            case OpenCommand:
                _showWindow();
                break;
            case ToggleMappingsCommand:
                if (_mappingCount() > 0) _toggleMappings();
                break;
            case ShowIssuesCommand:
                if (_issueCount() > 0) _showIssues();
                break;
            case ExitCommand:
                _exitApplication();
                break;
        }
    }

    private void RestoreWindowProcedure()
    {
        if (_previousWindowProcedure == 0)
        {
            return;
        }
        _ = SetWindowLongPtr(
            _windowHandle,
            WindowProcedureIndex,
            _previousWindowProcedure);
        _previousWindowProcedure = 0;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    internal struct NotificationIconData
    {
        public uint Size;
        public nint WindowHandle;
        public uint Id;
        public uint Flags;
        public uint CallbackMessage;
        public nint IconHandle;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string Tooltip;

        public uint State;
        public uint StateMask;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string Info;

        public uint TimeoutOrVersion;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]
        public string InfoTitle;

        public uint InfoFlags;
        public Guid ItemGuid;
        public nint BalloonIconHandle;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Point
    {
        public int X;
        public int Y;
    }

    private delegate nint WindowProcedure(
        nint windowHandle,
        uint message,
        nint wordParameter,
        nint longParameter);

    internal delegate bool NotifyIcon(uint message, ref NotificationIconData data);

    [DllImport("shell32.dll", EntryPoint = "Shell_NotifyIconW", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ShellNotifyIcon(
        uint message,
        ref NotificationIconData data);

    [DllImport("user32.dll", EntryPoint = "RegisterWindowMessageW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint RegisterWindowMessage(string message);

    [DllImport("user32.dll", EntryPoint = "LoadImageW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern nint LoadImage(
        nint instance,
        string name,
        uint type,
        int desiredWidth,
        int desiredHeight,
        uint loadFlags);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyIcon(nint iconHandle);

    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW", SetLastError = true)]
    private static extern nint SetWindowLongPtr(
        nint windowHandle,
        int index,
        nint newValue);

    [DllImport("user32.dll")]
    private static extern nint CallWindowProc(
        nint previousWindowProcedure,
        nint windowHandle,
        uint message,
        nint wordParameter,
        nint longParameter);

    [DllImport("user32.dll")]
    private static extern nint CreatePopupMenu();

    [DllImport("user32.dll", EntryPoint = "AppendMenuW", CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AppendMenu(
        nint menu,
        uint flags,
        uint id,
        string? text);

    [DllImport("user32.dll")]
    private static extern int TrackPopupMenu(
        nint menu,
        uint flags,
        int x,
        int y,
        int reserved,
        nint windowHandle,
        nint rectangle);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyMenu(nint menu);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetCursorPos(out Point point);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetForegroundWindow(nint windowHandle);
}
