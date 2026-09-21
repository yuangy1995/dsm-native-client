using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace LanStash.App.CloudDrive;

internal static class CloudFilesInterop
{
    internal const uint CallbackFetchData = 0;
    internal const uint CallbackCancelFetchData = 2;
    internal const uint CallbackFetchPlaceholders = 3;
    internal const uint CallbackCancelFetchPlaceholders = 4;
    internal const uint CallbackNotifyFileOpenCompletion = 5;
    internal const uint CallbackNotifyFileCloseCompletion = 6;
    internal const uint CallbackNotifyDelete = 9;
    internal const uint CallbackNotifyRename = 11;
    internal const uint CallbackNotifyRenameCompletion = 12;
    internal const uint CallbackNone = uint.MaxValue;
    internal const uint RegisterUpdate = 0x1;
    internal const uint RegisterMarkRootInSync = 0x4;
    internal const uint ConnectRequireFullPath = 0x4;
    internal const uint ConnectRequireProcessInfo = 0x2;
    internal const uint PlaceholderMarkInSync = 0x2;
    internal const uint InSyncPolicyDefault = 0;
    internal const uint PopulationPolicyFull = 2;
    internal const uint TransferPlaceholdersComplete = 2;
    internal const uint OperationTransferData = 0;
    internal const uint OperationTransferPlaceholders = 4;
    internal const uint OperationAckDelete = 6;
    internal const uint OperationAckRename = 7;
    internal const int StatusSuccess = 0;
    internal const int StatusUnsuccessful = unchecked((int)0xC0000001);
    internal const int StatusDiskFull = unchecked((int)0xC000007F);
    internal const int StatusAccessDenied = unchecked((int)0xC0000022);
    internal const uint FileShareReadWriteDelete = 0x00000007;
    internal const uint OpenExisting = 3;
    internal const uint FileFlagOpenReparsePoint = 0x00200000;
    internal const uint FileFlagBackupSemantics = 0x02000000;
    internal const uint GenericRead = 0x80000000;
    internal const uint PinStatePinned = 1;
    internal const uint PinStateUnpinned = 2;
    internal const uint SetPinRecurse = 0x1;

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    internal delegate void Callback(
        in CallbackInfo callbackInfo,
        IntPtr callbackParameters);

    [StructLayout(LayoutKind.Sequential)]
    internal struct ConnectionKey
    {
        internal long Value;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct TransferKey
    {
        internal long Value;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct RequestKey
    {
        internal long Value;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    internal struct CallbackRegistration
    {
        internal uint Type;
        internal Callback? Callback;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    internal struct SyncRegistration
    {
        internal uint StructSize;
        internal string ProviderName;
        internal string ProviderVersion;
        internal IntPtr SyncRootIdentity;
        internal uint SyncRootIdentityLength;
        internal IntPtr FileIdentity;
        internal uint FileIdentityLength;
        internal Guid ProviderId;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct HydrationPolicy
    {
        internal uint Primary;
        internal uint Modifier;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct PopulationPolicy
    {
        internal uint Primary;
        internal uint Modifier;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct SyncPolicies
    {
        internal uint StructSize;
        internal HydrationPolicy Hydration;
        internal PopulationPolicy Population;
        internal uint InSync;
        internal uint HardLink;
        internal uint PlaceholderManagement;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct CallbackInfo
    {
        internal uint StructSize;
        internal ConnectionKey ConnectionKey;
        internal IntPtr CallbackContext;
        internal IntPtr VolumeGuidName;
        internal IntPtr VolumeDosName;
        internal uint VolumeSerialNumber;
        internal long SyncRootFileId;
        internal IntPtr SyncRootIdentity;
        internal uint SyncRootIdentityLength;
        internal long FileId;
        internal long FileSize;
        internal IntPtr FileIdentity;
        internal uint FileIdentityLength;
        internal IntPtr NormalizedPath;
        internal TransferKey TransferKey;
        internal byte PriorityHint;
        internal IntPtr CorrelationVector;
        internal IntPtr ProcessInfo;
        internal RequestKey RequestKey;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct FileBasicInfo
    {
        internal long CreationTime;
        internal long LastAccessTime;
        internal long LastWriteTime;
        internal long ChangeTime;
        internal uint FileAttributes;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct FileStandardInfo
    {
        internal long AllocationSize;
        internal long EndOfFile;
        internal uint NumberOfLinks;
        internal byte DeletePending;
        internal byte Directory;
    }

    // CF_PLACEHOLDER_STANDARD_INFO 的固定前缀；FileIdentity 位于偏移 60，长度由返回值提供。
    [StructLayout(LayoutKind.Sequential)]
    internal struct PlaceholderStandardInfo
    {
        internal long OnDiskDataSize;
        internal long ValidatedDataSize;
        internal long ModifiedDataSize;
        internal long PropertiesSize;
        internal uint PinState;
        internal uint InSyncState;
        internal long FileId;
        internal long SyncRootFileId;
        internal uint FileIdentityLength;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct FileSystemMetadata
    {
        internal FileBasicInfo BasicInfo;
        internal long FileSize;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct PlaceholderCreateInfo
    {
        internal IntPtr RelativeFileName;
        internal FileSystemMetadata FileSystemMetadata;
        internal IntPtr FileIdentity;
        internal uint FileIdentityLength;
        internal uint Flags;
        internal int Result;
        internal long CreateUsn;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct OperationInfo
    {
        internal uint StructSize;
        internal uint Type;
        internal ConnectionKey ConnectionKey;
        internal TransferKey TransferKey;
        internal IntPtr CorrelationVector;
        internal IntPtr SyncStatus;
        internal RequestKey RequestKey;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct TransferDataParameters
    {
        internal uint ParamSize;
        internal uint Padding;
        internal uint Flags;
        internal int CompletionStatus;
        internal IntPtr Buffer;
        internal long Offset;
        internal long Length;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct TransferPlaceholdersParameters
    {
        internal uint ParamSize;
        internal uint Padding;
        internal uint Flags;
        internal int CompletionStatus;
        internal long PlaceholderTotalCount;
        internal IntPtr PlaceholderArray;
        internal uint PlaceholderCount;
        internal uint EntriesProcessed;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct AcknowledgeParameters
    {
        internal uint ParamSize;
        internal uint Padding;
        internal uint Flags;
        internal int CompletionStatus;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct RenameCallbackParameters
    {
        internal uint ParamSize;
        internal uint Padding;
        internal uint Flags;
        internal uint FlagsPadding;
        internal IntPtr Path;
    }

    [DllImport("cldapi.dll", CharSet = CharSet.Unicode)]
    internal static extern int CfRegisterSyncRoot(
        string syncRootPath,
        in SyncRegistration registration,
        in SyncPolicies policies,
        uint flags);

    [DllImport("cldapi.dll", CharSet = CharSet.Unicode)]
    internal static extern int CfUnregisterSyncRoot(string syncRootPath);

    [DllImport("cldapi.dll", CharSet = CharSet.Unicode)]
    internal static extern int CfConnectSyncRoot(
        string syncRootPath,
        [In] CallbackRegistration[] callbackTable,
        IntPtr callbackContext,
        uint connectFlags,
        out ConnectionKey connectionKey);

    [DllImport("cldapi.dll")]
    internal static extern int CfDisconnectSyncRoot(ConnectionKey connectionKey);

    [DllImport("cldapi.dll")]
    internal static extern int CfGetPlaceholderInfo(SafeFileHandle fileHandle, uint infoClass,
        IntPtr infoBuffer, uint infoBufferLength, out uint returnedLength);

    [DllImport("cldapi.dll")]
    internal static extern int CfUpdatePlaceholder(SafeFileHandle fileHandle, in FileSystemMetadata metadata,
        IntPtr fileIdentity, uint fileIdentityLength, IntPtr dehydrateRanges, uint dehydrateRangeCount,
        uint flags, IntPtr updateUsn, IntPtr overlapped);

    [DllImport("cldapi.dll")]
    internal static extern int CfSetInSyncState(SafeFileHandle fileHandle, uint state, uint flags, IntPtr usn);

    [DllImport("cldapi.dll")]
    internal static extern int CfConvertToPlaceholder(SafeFileHandle fileHandle, byte[] fileIdentity,
        uint fileIdentityLength, uint flags, IntPtr convertUsn, IntPtr overlapped);

    [DllImport("cldapi.dll")]
    internal static extern int CfRevertPlaceholder(SafeFileHandle fileHandle, uint flags, IntPtr overlapped);

    [DllImport("cldapi.dll", CharSet = CharSet.Unicode)]
    internal static extern int CfCreatePlaceholders(
        string baseDirectoryPath,
        [In, Out] PlaceholderCreateInfo[] placeholderArray,
        uint placeholderCount,
        uint createFlags,
        out uint entriesProcessed);

    [DllImport("cldapi.dll")]
    internal static extern int CfExecute(
        in OperationInfo operationInfo,
        IntPtr operationParameters);

    [DllImport("cldapi.dll", CharSet = CharSet.Unicode)]
    internal static extern int CfDehydratePlaceholder(
        IntPtr fileHandle,
        long startingOffset,
        long length,
        uint flags,
        IntPtr overlapped);

    [DllImport("cldapi.dll")]
    internal static extern int CfSetPinState(
        IntPtr fileHandle,
        uint pinState,
        uint pinFlags,
        IntPtr overlapped);

    [DllImport("cldapi.dll")]
    internal static extern int CfHydratePlaceholder(
        IntPtr fileHandle,
        long startingOffset,
        long length,
        uint flags,
        IntPtr overlapped);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    internal static extern uint GetCompressedFileSize(
        string fileName,
        out uint fileSizeHigh);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    internal static extern SafeFileHandle CreateFile(
        string fileName,
        uint desiredAccess,
        uint shareMode,
        IntPtr securityAttributes,
        uint creationDisposition,
        uint flagsAndAttributes,
        IntPtr templateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool SetFileInformationByHandle(SafeFileHandle fileHandle, int informationClass,
        in uint information, uint informationSize);

    [DllImport("kernel32.dll", SetLastError = true, EntryPoint = "GetFileInformationByHandleEx")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool GetFileStandardInfo(SafeFileHandle fileHandle, int informationClass,
        out FileStandardInfo information, uint informationSize);

    [DllImport("kernel32.dll", SetLastError = true, EntryPoint = "GetFileInformationByHandleEx")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool GetFileBasicInfo(SafeFileHandle fileHandle, int informationClass,
        out FileBasicInfo information, uint informationSize);

    [DllImport("kernel32.dll", EntryPoint = "SetFileInformationByHandle", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool SetFileBasicInfo(SafeFileHandle handle, int informationClass,
        in FileBasicInfo information, uint informationSize);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool GetVolumeNameForVolumeMountPoint(
        string volumeMountPoint,
        StringBuilder volumeName,
        uint bufferLength);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool GetVolumePathNamesForVolumeName(
        string volumeName,
        char[] volumePathNames,
        uint bufferLength,
        out uint returnLength);

    internal static void ThrowIfFailed(int result, string operation)
    {
        if (result < 0)
        {
            Marshal.ThrowExceptionForHR(result, new IntPtr(-1));
        }
    }
}
