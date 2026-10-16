using System;
using System.ComponentModel;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

// 仅由 run.ps1 的显式诊断开关加载，不进入生产 App 或合成宿主程序集。
// 结构依据：https://learn.microsoft.com/windows/win32/wer/stowed-exception-information-v2
public sealed class NativeUiCrashMonitor : IDisposable
{
    private readonly Process _process;
    private readonly string _logPath;
    private readonly Thread _thread;
    private readonly ManualResetEventSlim _ready = new ManualResetEventSlim();
    private volatile bool _stop;
    private Exception _startupError;
    private IntPtr _readHandle;
    private readonly Queue<string> _recent = new Queue<string>();
    private static readonly object SymbolLock = new object();

    private NativeUiCrashMonitor(Process process, string logPath)
    {
        _process = process;
        _logPath = logPath;
        _thread = new Thread(Monitor) { IsBackground = true, Name = "Synthetic UI native diagnostics" };
    }

    public static NativeUiCrashMonitor Attach(Process process, string expectedExecutable, string logPath)
    {
        if (IntPtr.Size != 8) throw new PlatformNotSupportedException("原生界面诊断要求 x64 PowerShell。");
        // Start-Process 返回时主映像可能尚未登记；等待可读映像，仍逐次核对本次进程。
        var started = Stopwatch.StartNew();
        string executable = null;
        while (executable == null && started.ElapsedMilliseconds < 5000)
        {
            process.Refresh();
            if (process.HasExited) throw new InvalidOperationException("合成宿主在附加诊断前已经退出。");
            executable = process.MainModule?.FileName;
            if (executable == null) Thread.Sleep(10);
        }
        if (executable == null) throw new TimeoutException("合成宿主映像未按时就绪。");
        if (!string.Equals(Path.GetFullPath(executable), Path.GetFullPath(expectedExecutable), StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("诊断目标不是本次启动的合成宿主。");
        var monitor = new NativeUiCrashMonitor(process, logPath);
        monitor._thread.Start();
        if (!monitor._ready.Wait(5000)) { monitor.Dispose(); throw new TimeoutException("原生诊断附加超时。"); }
        if (monitor._startupError != null) { monitor.Dispose(); throw new InvalidOperationException("原生诊断附加失败。", monitor._startupError); }
        return monitor;
    }

    private void Monitor()
    {
        var attached = false;
        var exited = false;
        var attachBreakpointSeen = false;
        try
        {
            if (!DebugActiveProcess((uint)_process.Id)) throw new Win32Exception(Marshal.GetLastWin32Error());
            attached = true;
            if (!DebugSetProcessKillOnExit(false)) throw new Win32Exception(Marshal.GetLastWin32Error());
            _readHandle = OpenProcess(0x0410, false, (uint)_process.Id);
            if (_readHandle == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            Log("Attached to synthetic UI host; no process memory dump is written.");
            _ready.Set();
            while (!_stop)
            {
                DebugEvent item;
                if (!WaitForDebugEventEx(out item, 100))
                {
                    var error = Marshal.GetLastWin32Error();
                    if (error == 121) continue;
                    throw new Win32Exception(error);
                }
                uint disposition = 0x00010002; // DBG_CONTINUE：普通调试事件与附加断点。
                try
                {
                    if (item.Code == 1)
                    {
                        var exception = item.Exception;
                        if (exception.Code == 0x80000003 && !attachBreakpointSeen && item.FirstChance != 0)
                        {
                            attachBreakpointSeen = true;
                        }
                        else
                        {
                            disposition = 0x80010001; // 不吞掉被测程序的异常。
                            Remember("First chance=0x" + exception.Code.ToString("X8") + "; parameters=" + exception.ParameterCount +
                                "; p0=0x" + exception.Information0.ToString("X") + "; p1=0x" + exception.Information1.ToString("X") + "; p2=0x" + exception.Information2.ToString("X"));
                            if (exception.Code == 0x40080201 && exception.ParameterCount >= 3 && exception.Information1 > 0 && exception.Information1 <= 512 && exception.Information2 != 0)
                            {
                                Remember("WinRT HRESULT=0x" + unchecked((uint)exception.Information0).ToString("X8"));
                                Remember("WinRT origin=" + Encoding.Unicode.GetString(Read(exception.Information2, checked((int)exception.Information1 * 2))).TrimEnd('\0'));
                                ReadOriginStack(item.ThreadId);
                            }
                            if (exception.Code == 0xC000027B || item.FirstChance == 0)
                            {
                                FlushRecent();
                                Log("Exception=0x" + exception.Code.ToString("X8") + "; firstChance=" + item.FirstChance + "; at=" + Describe(exception.Address));
                                if (exception.Code == 0xC000027B && exception.ParameterCount >= 2)
                                {
                                    var count = Math.Min(exception.Information1, 16UL);
                                    var pointers = Read(exception.Information0, checked((int)count * 8));
                                    for (var index = 0; index < (int)count; index++) ReadStowed(BitConverter.ToUInt64(pointers, index * 8), 0);
                                }
                            }
                        }
                    }
                    else if (item.Code == 3 || item.Code == 6)
                    {
                        // CREATE_PROCESS / LOAD_DLL 的映像文件句柄由调试器关闭。
                        if (item.FileHandle != IntPtr.Zero && item.FileHandle != new IntPtr(-1)) CloseHandle(item.FileHandle);
                    }
                    else if (item.Code == 8 && item.DebugStringLength > 0 && item.DebugStringAddress != IntPtr.Zero)
                    {
                        var characters = Math.Min(item.DebugStringLength, (ushort)2048);
                        // 此 Windows 的 Unicode 长度包含额外尾部空间；遇到终止符立即停止，避免读出相邻内容。
                        var unit = item.DebugStringUnicode == 0 ? 1 : 2;
                        var bytes = new List<byte>();
                        for (var index = 0; index < characters; index++)
                        {
                            var next = Read(unchecked((ulong)item.DebugStringAddress.ToInt64()) + (ulong)(index * unit), unit);
                            if (next[0] == 0 && (unit == 1 || next[1] == 0)) break;
                            bytes.AddRange(next);
                        }
                        Remember("Debug: " + (unit == 1 ? Encoding.UTF8 : Encoding.Unicode).GetString(bytes.ToArray()).TrimEnd('\r', '\n'));
                    }
                    else if (item.Code == 5)
                    {
                        exited = true;
                        if (item.ExitCode != 0 && item.ExitCode != uint.MaxValue) FlushRecent();
                        Log("Process exit=0x" + item.ExitCode.ToString("X8"));
                    }
                }
                catch (Exception error) { Log("Diagnostic read failed: " + error.GetType().Name + ": " + error.Message); }
                finally
                {
                    if (!ContinueDebugEvent(item.ProcessId, item.ThreadId, disposition))
                        throw new Win32Exception(Marshal.GetLastWin32Error());
                }
                if (exited) break;
            }
        }
        catch (Exception error)
        {
            _startupError = error;
            Log("Monitor error: " + error.GetType().Name + ": " + error.Message);
        }
        finally
        {
            _ready.Set();
            if (attached && !exited && !DebugActiveProcessStop((uint)_process.Id))
                Log("Detach error=" + Marshal.GetLastWin32Error());
            if (_readHandle != IntPtr.Zero) CloseHandle(_readHandle);
        }
    }

    private void ReadStowed(ulong address, int depth)
    {
        if (address == 0 || depth > 3) return;
        var header = Read(address, 8);
        var size = BitConverter.ToUInt32(header, 0);
        var signature = BitConverter.ToUInt32(header, 4);
        if (size < 40 || size > 256 || (signature != 0x53453031 && signature != 0x53453032))
        { Log("Unrecognized stowed header: size=" + size + "; signature=0x" + signature.ToString("X8")); return; }
        var data = Read(address, (int)size);
        var result = BitConverter.ToUInt32(data, 8);
        var form = BitConverter.ToUInt32(data, 12) & 3;
        Log("Stowed HRESULT=0x" + result.ToString("X8") + "; form=" + form + "; depth=" + depth);
        if (form == 1)
        {
            Log("Origin=" + Describe(new IntPtr(unchecked((long)BitConverter.ToUInt64(data, 16)))));
            var wordSize = BitConverter.ToUInt32(data, 24);
            var words = Math.Min(BitConverter.ToUInt32(data, 28), 128U);
            if (wordSize == 8 && words > 0)
            {
                var stack = Read(BitConverter.ToUInt64(data, 32), checked((int)words * 8));
                for (var index = 0; index < words; index++) Log("  " + Describe(new IntPtr(unchecked((long)BitConverter.ToUInt64(stack, index * 8)))));
            }
        }
        else if (form == 2)
        {
            // 只在隔离合成宿主中读取有界错误文本；不读取或保存其他业务内存。
            var pointer = BitConverter.ToUInt64(data, 16);
            var message = new StringBuilder();
            for (var index = 0; pointer != 0 && index < 1024; index++)
            {
                var character = BitConverter.ToUInt16(Read(pointer + (ulong)(index * 2), 2), 0);
                if (character == 0) break;
                message.Append((char)character);
            }
            Log("Text=" + message);
        }
        if (size >= 56)
        {
            var nestedType = BitConverter.ToUInt32(data, 40);
            Log("NestedType=0x" + nestedType.ToString("X8"));
            if (nestedType == 0x574F5453) ReadStowed(BitConverter.ToUInt64(data, 48), depth + 1);
        }
    }

    private byte[] Read(ulong address, int count)
    {
        var bytes = new byte[count];
        UIntPtr actual;
        if (!ReadProcessMemory(_readHandle, new IntPtr(unchecked((long)address)), bytes, (UIntPtr)count, out actual) || actual.ToUInt64() != (ulong)count)
            throw new Win32Exception(Marshal.GetLastWin32Error());
        return bytes;
    }

    private void ReadOriginStack(uint threadId)
    {
        // 调试事件已暂停目标线程；只读取寄存器和返回地址，不写转储、不下载符号。
        // AMD64 CONTEXT / STACKFRAME64 布局依据 Win32 SDK，预留对齐和结构尾部空间。
        lock (SymbolLock)
        {
            var thread = OpenThread(0x0008, false, threadId);
            if (thread == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            var allocation = Marshal.AllocHGlobal(1264);
            var context = new IntPtr((allocation.ToInt64() + 15) & ~15L);
            var frame = Marshal.AllocHGlobal(512);
            var initialized = false;
            try
            {
                Marshal.Copy(new byte[1232], 0, context, 1232);
                Marshal.Copy(new byte[512], 0, frame, 512);
                Marshal.WriteInt32(context, 48, 0x00100003);
                if (!GetThreadContext(thread, context)) throw new Win32Exception(Marshal.GetLastWin32Error());
                if (!SymInitialize(_readHandle, Path.GetDirectoryName(_process.MainModule.FileName), true))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                initialized = true;
                Marshal.WriteInt64(frame, 0, Marshal.ReadInt64(context, 248)); Marshal.WriteInt32(frame, 12, 3);
                Marshal.WriteInt64(frame, 32, Marshal.ReadInt64(context, 160)); Marshal.WriteInt32(frame, 44, 3);
                Marshal.WriteInt64(frame, 48, Marshal.ReadInt64(context, 152)); Marshal.WriteInt32(frame, 60, 3);
                FunctionTable table = SymFunctionTableAccess64;
                ModuleBase module = SymGetModuleBase64;
                Remember("Origin instruction: " + Describe(new IntPtr(Marshal.ReadInt64(context, 248))));
                for (var index = 0; index < 96; index++)
                {
                    if (!StackWalk64(0x8664, _readHandle, thread, frame, context, IntPtr.Zero, table, module, IntPtr.Zero))
                    { Remember("Origin stack ended: frames=" + index + "; error=" + Marshal.GetLastWin32Error()); break; }
                    var address = Marshal.ReadInt64(frame);
                    if (address == 0) break;
                    var description = Describe(new IntPtr(address));
                    if (description.StartsWith("unresolved+", StringComparison.Ordinal))
                    { Remember("Origin stack stopped at non-module code; managed frames are not inferred."); break; }
                    Remember("Origin stack: " + description + ResolveSymbol(unchecked((ulong)address)));
                }
            }
            finally
            {
                if (initialized) SymCleanup(_readHandle);
                Marshal.FreeHGlobal(frame); Marshal.FreeHGlobal(allocation); CloseHandle(thread);
            }
        }
    }

    private string ResolveSymbol(ulong address)
    {
        var symbol = Marshal.AllocHGlobal(1112);
        try
        {
            Marshal.Copy(new byte[1112], 0, symbol, 1112);
            Marshal.WriteInt32(symbol, 0, 88); Marshal.WriteInt32(symbol, 80, 1024);
            ulong displacement;
            if (!SymFromAddr(_readHandle, address, out displacement, symbol)) return "";
            var length = Math.Min(1024, Marshal.ReadInt32(symbol, 76));
            return " (" + Marshal.PtrToStringAnsi(IntPtr.Add(symbol, 84), length) + "+0x" + displacement.ToString("X") + ")";
        }
        finally { Marshal.FreeHGlobal(symbol); }
    }

    private string Describe(IntPtr address)
    {
        var value = unchecked((ulong)address.ToInt64());
        // 使用独立查询对象，避免与主脚本等待退出竞争，也避免沿用附加时的模块缓存。
        using var snapshot = Process.GetProcessById(_process.Id);
        foreach (ProcessModule module in snapshot.Modules)
        {
            var start = unchecked((ulong)module.BaseAddress.ToInt64());
            if (value >= start && value - start < (ulong)module.ModuleMemorySize)
                return module.ModuleName + "+0x" + (value - start).ToString("X");
        }
        return "unresolved+0x" + value.ToString("X");
    }

    private void Log(string value) { File.AppendAllText(_logPath, value + Environment.NewLine, Encoding.UTF8); }
    private void Remember(string value) { _recent.Enqueue(value); while (_recent.Count > 256) _recent.Dequeue(); }
    private void FlushRecent() { while (_recent.Count > 0) Log(_recent.Dequeue()); }

    public void Dispose()
    {
        _stop = true;
        if (!_thread.Join(5000)) throw new TimeoutException("原生诊断线程未按时退出。");
        _ready.Dispose();
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ExceptionRecord
    {
        public uint Code, Flags;
        public IntPtr Record, Address;
        public uint ParameterCount, Alignment;
        public ulong Information0, Information1, Information2, Information3, Information4, Information5, Information6, Information7,
            Information8, Information9, Information10, Information11, Information12, Information13, Information14;
    }
    [StructLayout(LayoutKind.Explicit, Size = 176)]
    private struct DebugEvent
    {
        [FieldOffset(0)] public uint Code;
        [FieldOffset(4)] public uint ProcessId;
        [FieldOffset(8)] public uint ThreadId;
        [FieldOffset(16)] public ExceptionRecord Exception;
        [FieldOffset(168)] public uint FirstChance;
        [FieldOffset(16)] public IntPtr FileHandle;
        [FieldOffset(16)] public uint ExitCode;
        [FieldOffset(16)] public IntPtr DebugStringAddress;
        [FieldOffset(24)] public ushort DebugStringUnicode;
        [FieldOffset(26)] public ushort DebugStringLength;
    }
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool DebugActiveProcess(uint processId);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool DebugActiveProcessStop(uint processId);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool DebugSetProcessKillOnExit(bool kill);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool WaitForDebugEventEx(out DebugEvent item, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool ContinueDebugEvent(uint processId, uint threadId, uint status);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr OpenProcess(uint access, bool inherit, uint processId);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr OpenThread(uint access, bool inherit, uint threadId);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetThreadContext(IntPtr thread, IntPtr context);
    private delegate IntPtr FunctionTable(IntPtr process, ulong address);
    private delegate ulong ModuleBase(IntPtr process, ulong address);
    [DllImport("dbghelp.dll", SetLastError = true, CharSet = CharSet.Ansi)] private static extern bool SymInitialize(IntPtr process, string path, bool invade);
    [DllImport("dbghelp.dll", SetLastError = true)] private static extern bool SymCleanup(IntPtr process);
    [DllImport("dbghelp.dll")] private static extern IntPtr SymFunctionTableAccess64(IntPtr process, ulong address);
    [DllImport("dbghelp.dll")] private static extern ulong SymGetModuleBase64(IntPtr process, ulong address);
    [DllImport("dbghelp.dll", SetLastError = true)] private static extern bool SymFromAddr(IntPtr process, ulong address, out ulong displacement, IntPtr symbol);
    [DllImport("dbghelp.dll", SetLastError = true)] private static extern bool StackWalk64(uint machine, IntPtr process, IntPtr thread, IntPtr frame, IntPtr context,
        IntPtr read, FunctionTable table, ModuleBase module, IntPtr translate);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool ReadProcessMemory(IntPtr process, IntPtr address, byte[] buffer, UIntPtr size, out UIntPtr read);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
}
