using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;

namespace LanStash.App.Platform.Office;

public enum OfficePreviewResult { Ready, NotInstalled, Failed }

/// <summary>只使用已注册的系统进程外预览处理程序，不加载第三方 DLL 或修改注册表。</summary>
public sealed class WindowsOfficePreviewHost : IDisposable
{
    private readonly FrameworkElement _surface;
    private readonly Action _leavePreview;
    private readonly Action _closePreview;
    private IPreviewHandler? _handler;
    private IStream? _stream;
    private nint _shellItem;
    private bool _initialized;
    private PreviewFrame? _frame;
    private nint _window;
    private bool _disposed;
    private bool _suspended;
    private ElementTheme? _theme;
    private Rect _lastRect;

    public WindowsOfficePreviewHost(FrameworkElement surface, Action leavePreview, Action closePreview)
    {
        _surface = surface; _leavePreview = leavePreview; _closePreview = closePreview;
        surface.LayoutUpdated += LayoutUpdated;
        surface.Unloaded += Unloaded;
    }

    public OfficePreviewResult Show(string localPath, nint parentWindow, string accessibleName)
    {
        if (_disposed || _handler is not null) throw new InvalidOperationException("office.preview-active");
        if (!OfficeDocumentFormat.SupportsExtension(Path.GetExtension(localPath)) || !File.Exists(localPath)) return OfficePreviewResult.Failed;
        var text = new StringBuilder(64); uint capacity = 64;
        var association = AssocQueryString(0, 16, Path.GetExtension(localPath), typeof(IPreviewHandler).GUID.ToString("B"), text, ref capacity);
        if (association != 0 || !Guid.TryParse(text.ToString(), out var classId)) return OfficePreviewResult.NotInstalled;
        try
        {
            var interfaceId = typeof(IPreviewHandler).GUID;
            // CLSCTX_LOCAL_SERVER 强制系统代理；不回退 CLSCTX_INPROC_SERVER。
            Marshal.ThrowExceptionForHR(CoCreateInstance(ref classId, 0, 4, ref interfaceId, out _handler));
            _window = CreateWindowEx(0, "STATIC", accessibleName, 0x46010000, 0, 0, 1, 1, parentWindow, 0, 0, 0);
            if (_window == 0) throw new IOException("office.preview-window-unavailable");
            _frame = new PreviewFrame(_window, key => _surface.DispatcherQueue.TryEnqueue(() =>
            { if (!_disposed) { if (key == 27) _closePreview(); else _leavePreview(); } }));
            if (_handler is IObjectWithSite site) Marshal.ThrowExceptionForHR(site.SetSite(_frame));
            if (_handler is IInitializeWithStream stream)
            {
                Marshal.ThrowExceptionForHR(SHCreateStreamOnFileEx(localPath, 0x20, 0, false, 0, out _stream));
                Marshal.ThrowExceptionForHR(stream.Initialize(_stream, 0));
            }
            else if (_handler is IInitializeWithFile file)
                Marshal.ThrowExceptionForHR(file.Initialize(localPath, 0));
            else if (_handler is IInitializeWithItem item)
            {
                var itemId = new Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE");
                Marshal.ThrowExceptionForHR(SHCreateItemFromParsingName(localPath, 0, ref itemId, out _shellItem));
                Marshal.ThrowExceptionForHR(item.Initialize(_shellItem, 0));
            }
            else throw new NotSupportedException("office.preview-initializer-unavailable");
            _initialized = true;
            var rectangle = new Rect(0, 0, Math.Max(1, (int)_surface.ActualWidth), Math.Max(1, (int)_surface.ActualHeight));
            Marshal.ThrowExceptionForHR(_handler.SetWindow(_window, ref rectangle));
            ApplyTheme();
            Marshal.ThrowExceptionForHR(_handler.DoPreview());
            UpdateBounds();
            return OfficePreviewResult.Ready;
        }
        catch { Release(); return OfficePreviewResult.Failed; }
    }

    public void Focus() { if (_handler is not null) _ = _handler.SetFocus(); }
    public void Suspend(bool suspended) { _suspended = suspended; UpdateBounds(); }
    private void LayoutUpdated(object? sender, object args) => UpdateBounds();
    private void Unloaded(object sender, RoutedEventArgs args) => Dispose();

    private void UpdateBounds()
    {
        if (_window == 0 || _handler is null || _disposed) return;
        var root = _surface.XamlRoot;
        if (_suspended || !_surface.IsLoaded || root?.Content is not UIElement content ||
            _surface.ActualWidth <= 0 || _surface.ActualHeight <= 0 || VisualTreeHelper.GetOpenPopupsForXamlRoot(root).Count > 0)
        { ShowWindow(_window, 0); return; }
        for (DependencyObject? current = _surface; current is not null; current = VisualTreeHelper.GetParent(current))
            if (current is UIElement { Visibility: Visibility.Collapsed }) { ShowWindow(_window, 0); return; }
        var origin = _surface.TransformToVisual(content).TransformPoint(new Windows.Foundation.Point());
        var scale = root.RasterizationScale;
        var rectangle = new Rect((int)Math.Round(origin.X * scale), (int)Math.Round(origin.Y * scale),
            (int)Math.Round(_surface.ActualWidth * scale), (int)Math.Round(_surface.ActualHeight * scale));
        if (rectangle != _lastRect)
        {
            _lastRect = rectangle;
            SetWindowPos(_window, 0, rectangle.Left, rectangle.Top, rectangle.Right, rectangle.Bottom, 0x0014);
            var client = new Rect(0, 0, rectangle.Right, rectangle.Bottom);
            _ = _handler.SetRect(ref client);
        }
        ApplyTheme(); ShowWindow(_window, 8);
    }

    private void ApplyTheme()
    {
        if (_theme == _surface.ActualTheme) return;
        _theme = _surface.ActualTheme;
        if (_handler is IPreviewHandlerVisuals visuals)
        {
            _ = visuals.SetBackgroundColor(_theme == ElementTheme.Dark ? 0x202020u : 0xFFFFFFu);
            _ = visuals.SetTextColor(_theme == ElementTheme.Dark ? 0xFFFFFFu : 0x000000u);
        }
    }

    private void Release()
    {
        if (_window != 0) ShowWindow(_window, 0);
        if (_handler is not null)
        {
            try { if (_initialized) _ = _handler.Unload(); if (_handler is IObjectWithSite site) _ = site.SetSite(null); }
            catch (COMException) { }
            finally { Marshal.FinalReleaseComObject(_handler); _handler = null; }
        }
        if (_stream is not null) { Marshal.FinalReleaseComObject(_stream); _stream = null; }
        if (_shellItem != 0) { Marshal.Release(_shellItem); _shellItem = 0; }
        _initialized = false;
        _frame = null;
        if (_window != 0) { DestroyWindow(_window); _window = 0; }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true; _surface.LayoutUpdated -= LayoutUpdated; _surface.Unloaded -= Unloaded; Release();
    }

    [ComVisible(true), ClassInterface(ClassInterfaceType.None)]
    // COM 回调类型必须公开，否则系统处理程序无法查询键盘与窗口接口。
    public sealed class PreviewFrame(nint window, Action<int> forward) : IPreviewHandlerFrame, IOleWindow
    {
        public int GetWindowContext(out FrameInfo info) { info = default; return 0; }
        public int TranslateAccelerator(ref Message message)
        {
            if (message.Id is 0x100 or 0x104 && message.WParam is 9 or 27)
            { forward((int)message.WParam); return 0; }
            return 1;
        }
        public int GetWindow(out nint result) { result = window; return 0; }
        public int ContextSensitiveHelp(bool enterMode) => unchecked((int)0x80004001);
    }

    [StructLayout(LayoutKind.Sequential)]
    private record struct Rect(int Left, int Top, int Right, int Bottom);
    [StructLayout(LayoutKind.Sequential)]
    public struct Message { public nint Window; public uint Id; public nuint WParam; public nint LParam; public uint Time; public int X; public int Y; public uint Private; }
    [StructLayout(LayoutKind.Sequential)]
    public struct FrameInfo { public nint Accelerators; public uint Count; }

    [ComImport, Guid("8895B1C6-B41F-4C1C-A562-0D564250836F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IPreviewHandler
    {
        [PreserveSig] int SetWindow(nint window, ref Rect rectangle);
        [PreserveSig] int SetRect(ref Rect rectangle);
        [PreserveSig] int DoPreview();
        [PreserveSig] int Unload();
        [PreserveSig] int SetFocus();
        [PreserveSig] int QueryFocus(out nint window);
        [PreserveSig] int TranslateAccelerator(ref Message message);
    }
    [ComImport, Guid("B824B49D-22AC-4161-AC8A-9916E8FA3F7F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IInitializeWithStream { [PreserveSig] int Initialize(IStream stream, uint mode); }
    [ComImport, Guid("B7D14566-0509-4CCE-A71F-0A554233BD9B"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IInitializeWithFile { [PreserveSig] int Initialize([MarshalAs(UnmanagedType.LPWStr)] string file, uint mode); }
    [ComImport, Guid("7F73BE3F-FB79-493C-A6C7-7EE14E245841"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IInitializeWithItem { [PreserveSig] int Initialize(nint item, uint mode); }
    [ComImport, Guid("FC4801A3-2BA9-11CF-A229-00AA003D7352"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IObjectWithSite
    {
        [PreserveSig] int SetSite([MarshalAs(UnmanagedType.IUnknown)] object? site);
        [PreserveSig] int GetSite(ref Guid interfaceId, out nint site);
    }
    [ComVisible(true), Guid("FEC87AAF-35F9-447A-ADB7-20234491401A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IPreviewHandlerFrame
    {
        [PreserveSig] int GetWindowContext(out FrameInfo info);
        [PreserveSig] int TranslateAccelerator(ref Message message);
    }
    [ComVisible(true), Guid("00000114-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IOleWindow
    {
        [PreserveSig] int GetWindow(out nint window);
        [PreserveSig] int ContextSensitiveHelp([MarshalAs(UnmanagedType.Bool)] bool enterMode);
    }
    [ComImport, Guid("196BF9A5-B346-4EF0-AA1E-5DCDB76768B1"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IPreviewHandlerVisuals
    {
        [PreserveSig] int SetBackgroundColor(uint color);
        [PreserveSig] int SetFont(nint font);
        [PreserveSig] int SetTextColor(uint color);
    }
    [DllImport("shlwapi.dll", CharSet = CharSet.Unicode, EntryPoint = "AssocQueryStringW")]
    private static extern int AssocQueryString(uint flags, uint kind, string association, string extra, StringBuilder output, ref uint length);
    [DllImport("ole32.dll", ExactSpelling = true)]
    private static extern int CoCreateInstance(ref Guid classId, nint outer, uint context, ref Guid interfaceId,
        [MarshalAs(UnmanagedType.Interface)] out IPreviewHandler handler);
    [DllImport("shlwapi.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int SHCreateStreamOnFileEx(string file, uint mode, uint attributes, [MarshalAs(UnmanagedType.Bool)] bool create, nint template, out IStream stream);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int SHCreateItemFromParsingName(string path, nint bindContext, ref Guid interfaceId, out nint item);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "CreateWindowExW", SetLastError = true)]
    private static extern nint CreateWindowEx(uint exStyle, string className, string title, uint style, int x, int y, int width, int height, nint parent, nint menu, nint instance, nint parameter);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetWindowPos(nint window, nint after, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)] private static extern bool ShowWindow(nint window, int command);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)] private static extern bool DestroyWindow(nint window);
}
