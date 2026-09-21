using System.Runtime.InteropServices;

// 仅供合成检查调用；调用方必须先校验测试根与精确文件名，不枚举或清空系统回收站。
internal static class ShellRecycle
{
    // 方法顺序来自 Windows SDK 的 IFileOperation 声明，未调用的接口也保留原始槽位。
    [ComImport, Guid("947aab5f-0a5c-4c13-b4d6-4bf7836fc9f8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IFileOperation
    {
        [PreserveSig] int Advise(IntPtr sink, out uint cookie);
        [PreserveSig] int Unadvise(uint cookie);
        [PreserveSig] int SetOperationFlags(uint flags);
        [PreserveSig] int SetProgressMessage([MarshalAs(UnmanagedType.LPWStr)] string message);
        [PreserveSig] int SetProgressDialog(IntPtr dialog);
        [PreserveSig] int SetProperties(IntPtr properties);
        [PreserveSig] int SetOwnerWindow(IntPtr window);
        [PreserveSig] int ApplyPropertiesToItem(IntPtr item);
        [PreserveSig] int ApplyPropertiesToItems(IntPtr items);
        [PreserveSig] int RenameItem(IntPtr item, [MarshalAs(UnmanagedType.LPWStr)] string name, IntPtr sink);
        [PreserveSig] int RenameItems(IntPtr items, [MarshalAs(UnmanagedType.LPWStr)] string name);
        [PreserveSig] int MoveItem(IntPtr item, IntPtr folder, [MarshalAs(UnmanagedType.LPWStr)] string name, IntPtr sink);
        [PreserveSig] int MoveItems(IntPtr items, IntPtr folder);
        [PreserveSig] int CopyItem(IntPtr item, IntPtr folder, [MarshalAs(UnmanagedType.LPWStr)] string name, IntPtr sink);
        [PreserveSig] int CopyItems(IntPtr items, IntPtr folder);
        [PreserveSig] int DeleteItem(IntPtr item, IntPtr sink);
        [PreserveSig] int DeleteItems(IntPtr items);
        [PreserveSig] int NewItem(IntPtr folder, uint attributes, [MarshalAs(UnmanagedType.LPWStr)] string name,
            [MarshalAs(UnmanagedType.LPWStr)] string template, IntPtr sink);
        [PreserveSig] int PerformOperations();
        [PreserveSig] int GetAnyOperationsAborted([MarshalAs(UnmanagedType.Bool)] out bool aborted);
    }
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = true)]
    private static extern int SHCreateItemFromParsingName(string path, IntPtr context, in Guid iid, out IntPtr item);

    [DllImport("ole32.dll")]
    private static extern int OleInitialize(IntPtr reserved);
    [DllImport("ole32.dll")]
    private static extern void OleUninitialize();

    internal static void Request(string path, bool performDelete = true)
    {
        Exception? failure = null;
        var thread = new Thread(() =>
        {
            try
            {
                Marshal.ThrowExceptionForHR(OleInitialize(IntPtr.Zero));
                Console.WriteLine("Shell 检查：STA/OLE 已初始化。");
                try { RequestCore(path, performDelete); } finally { OleUninitialize(); }
            }
            catch (Exception error) { failure = error; }
        });
        thread.SetApartmentState(ApartmentState.STA); thread.Start(); thread.Join();
        if (failure is not null) throw failure;
    }

    private static void RequestCore(string path, bool performDelete)
    {
        if (!Path.IsPathFullyQualified(path) || path.IndexOfAny(['*', '?', '\0']) >= 0) throw new ArgumentException("无效合成路径");
        var operation = (IFileOperation)Activator.CreateInstance(Type.GetTypeFromCLSID(new("3ad05575-8857-4850-9277-11b85bdb8e09"), throwOnError: true)!)!;
        Console.WriteLine("Shell 检查：文件操作对象已创建。");
        IntPtr item = IntPtr.Zero;
        try
        {
            Marshal.ThrowExceptionForHR(operation.SetOperationFlags(0x00080000 | 0x654)); // RECYCLEONDELETE、ALLOWUNDO、NO_UI。
            Console.WriteLine("Shell 检查：操作选项已设置。");
            Marshal.ThrowExceptionForHR(SHCreateItemFromParsingName(path, IntPtr.Zero, new Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe"), out item));
            Console.WriteLine("Shell 检查：目标已绑定。");
            if (!performDelete) return;
            Marshal.ThrowExceptionForHR(operation.DeleteItem(item, IntPtr.Zero));
            Console.WriteLine("Shell 检查：开始执行回收站操作。");
            _ = operation.PerformOperations(); // 预期被提供方拒绝，父进程核对原文件和回调，不将 HRESULT 当作成功。
        }
        finally { if (item != IntPtr.Zero) Marshal.Release(item); Marshal.FinalReleaseComObject(operation); }
    }
}
