<#
在独立无配置 PowerShell 子进程中生成合成 WinRT 原生异常，验证诊断器确实读取错误依据。
不运行 App、不访问 NAS、不创建内存转储，也不修改系统错误报告设置。
#>
param([switch]$ProbeChild, [switch]$FailFastChild)
$ErrorActionPreference = 'Stop'
if ($ProbeChild) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class SyntheticNativeException
{
    [DllImport("kernel32.dll")] private static extern void RaiseException(uint code, uint flags, uint count, IntPtr arguments);
    [DllImport("combase.dll", CharSet = CharSet.Unicode)] private static extern bool RoOriginateErrorW(int error, uint length, string message);
    [DllImport("combase.dll")] private static extern void RoFailFastWithErrorContext(int error);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern void OutputDebugStringW(string message);
    public static void Raise(bool failFast)
    {
        OutputDebugStringW("synthetic-debug-context");
        RoOriginateErrorW(unchecked((int)0x80070057), 22, "synthetic-origin-error");
        if (failFast) RoFailFastWithErrorContext(unchecked((int)0x80070057));
        var record = Marshal.AllocHGlobal(56);
        var text = Marshal.StringToHGlobalUni("synthetic-native-error");
        var array = Marshal.AllocHGlobal(8);
        var arguments = Marshal.AllocHGlobal(16);
        try
        {
            Marshal.Copy(new byte[56], 0, record, 56);
            Marshal.WriteInt32(record, 0, 56);
            Marshal.WriteInt32(record, 4, 0x53453032);
            Marshal.WriteInt32(record, 8, unchecked((int)0x80004005));
            Marshal.WriteInt32(record, 12, 2);
            Marshal.WriteIntPtr(record, 16, text);
            Marshal.WriteIntPtr(array, record);
            Marshal.WriteIntPtr(arguments, array);
            Marshal.WriteInt64(arguments, 8, 1);
            RaiseException(0xC000027B, 0, 2, arguments);
        }
        finally
        {
            Marshal.FreeHGlobal(arguments); Marshal.FreeHGlobal(array);
            Marshal.FreeHGlobal(text); Marshal.FreeHGlobal(record);
        }
    }
}
'@
    try { [SyntheticNativeException]::Raise($FailFastChild.IsPresent) } catch { exit 7 }
    exit 0
}

Add-Type -Path (Join-Path $PSScriptRoot 'NativeUiCrashMonitor.cs')
$diagnosticRoot = Join-Path $PSScriptRoot ('../../dist/native-diagnostics-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $diagnosticRoot | Out-Null
$executable = (Get-Process -Id $PID).Path
foreach ($failFast in @($false, $true)) {
$arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', ('"' + $PSCommandPath + '"'), '-ProbeChild')
if ($failFast) { $arguments += '-FailFastChild' }
$child = Start-Process -FilePath $executable -ArgumentList $arguments -WindowStyle Hidden -PassThru
$monitor = $null
try {
    $log = Join-Path $diagnosticRoot $(if ($failFast) { 'synthetic-fail-fast.txt' } else { 'synthetic-native.txt' })
    $monitor = [NativeUiCrashMonitor]::Attach($child, $executable, $log)
    if (-not $child.WaitForExit(15000)) { throw '原生异常探针未按时退出。' }
    $monitor.Dispose(); $monitor = $null
    $evidence = Get-Content -LiteralPath $log -Raw
    # 本机真实 RoFailFast 只交付退出事件；必须从之前的 WinRT 起源事件保留原始错误。
    $captured = if ($failFast) { $evidence -match 'Process exit=0xC000027B' -and $evidence -match 'WinRT HRESULT=0x80070057' }
        else { $evidence -match 'Exception=0xC000027B' -and $evidence -match 'Stowed HRESULT=0x80004005; form=2' -and $evidence -match 'Text=synthetic-native-error' }
    if (-not $captured -or $evidence -notmatch 'Origin stack: KERNELBASE.dll' -or
        $evidence -notmatch '(?m)^Debug: synthetic-debug-context\r?$' -or $evidence.IndexOf([char]0) -ge 0 -or
        $evidence -notmatch 'synthetic-origin-error' -or $evidence -match 'Monitor error|Diagnostic read failed') {
        throw '原生诊断没有完整记录合成异常。'
    }
    Write-Output "原生诊断探针通过（FailFast=$failFast）：捕获异常代码、原始 HRESULT 和合成错误文本，未吞掉异常。"
}
finally {
    if (-not $child.HasExited) { $child.Kill(); $child.WaitForExit() }
    if ($null -ne $monitor) { $monitor.Dispose() }
    $child.Dispose()
}
}
