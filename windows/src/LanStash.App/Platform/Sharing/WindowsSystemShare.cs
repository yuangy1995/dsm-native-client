using LanStash.App.Localization;
using Microsoft.UI.Xaml;
using System.Runtime.InteropServices;
using Windows.ApplicationModel.DataTransfer;
using WinRT;
using WinRT.Interop;

namespace LanStash.App.Platform.Sharing;

internal sealed class WindowsSystemShare
{
    private static readonly Guid DataTransferManagerId =
        new(0xa5caee9b, 0x8708, 0x49d1, 0x8d, 0x36, 0x67, 0xd2, 0x5a, 0x8d, 0xa0, 0x0c);

    private readonly Func<Window?> _window;
    private IntPtr _windowHandle;
    private IDataTransferManagerInterop? _interop;
    private DataTransferManager? _manager;
    private Uri? _pendingUri;

    public WindowsSystemShare(Func<Window?> window)
    {
        _window = window;
    }

    public bool IsAvailable => TryEnsureShareManager();

    public bool TryShow(Uri value)
    {
        ArgumentNullException.ThrowIfNull(value);
        if (!TryEnsureShareManager() || _interop is null || _windowHandle == IntPtr.Zero)
        {
            return false;
        }

        _pendingUri = value;
        try
        {
            _interop.ShowShareUIForWindow(_windowHandle);
            return true;
        }
        catch
        {
            _pendingUri = null;
            return false;
        }
    }

    private bool TryEnsureShareManager()
    {
        if (_manager is not null && _interop is not null && _windowHandle != IntPtr.Zero)
        {
            return true;
        }

        var window = _window();
        if (window is null)
        {
            return false;
        }

        var windowHandle = WindowNative.GetWindowHandle(window);
        if (windowHandle == IntPtr.Zero)
        {
            return false;
        }

        try
        {
            var interop = DataTransferManager.As<IDataTransferManagerInterop>();
            var dataTransferManagerId = DataTransferManagerId;
            var managerPointer = interop.GetForWindow(windowHandle, ref dataTransferManagerId);
            var manager = MarshalInterface<DataTransferManager>.FromAbi(managerPointer);
            manager.DataRequested += ShareManager_DataRequested;
            _windowHandle = windowHandle;
            _interop = interop;
            _manager = manager;
            return true;
        }
        catch
        {
            _windowHandle = IntPtr.Zero;
            _interop = null;
            _manager = null;
            return false;
        }
    }

    private void ShareManager_DataRequested(
        DataTransferManager sender,
        DataRequestedEventArgs args)
    {
        var uri = _pendingUri;
        _pendingUri = null;
        if (uri is null)
        {
            args.Request.FailWithDisplayText(string.Empty);
            return;
        }

        args.Request.Data.Properties.Title =
            LocalizationService.Current.Get("FileShareLinkSystemShareTitle");
        args.Request.Data.SetWebLink(uri);
        args.Request.Data.RequestedOperation = DataPackageOperation.Copy;
    }

    [ComImport]
    [Guid("3A3DCD6C-3EAB-43DC-BCDE-45671CE800C8")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IDataTransferManagerInterop
    {
        IntPtr GetForWindow(
            [In] IntPtr appWindow,
            [In] ref Guid riid);

        void ShowShareUIForWindow(
            [In] IntPtr appWindow);
    }
}
