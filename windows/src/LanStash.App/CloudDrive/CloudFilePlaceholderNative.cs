using System.Runtime.InteropServices;
using System.Text;
using System.Security.Cryptography;
using Microsoft.Win32.SafeHandles;

namespace LanStash.App.CloudDrive;

internal static class CloudFilePlaceholderNative
{
    internal static bool ReleaseCachedContent(string localPath, string identity)
    {
        // 不请求数据、不临时取消固定离线；同一句柄覆盖检查、恢复只读和系统释放。
        using var handle = CloudFilesInterop.CreateFile(localPath, 0x50080, 0, IntPtr.Zero, CloudFilesInterop.OpenExisting,
            CloudFilesInterop.FileFlagOpenReparsePoint, IntPtr.Zero);
        if (handle.IsInvalid) throw new IOException("cloud.cache.file_busy", Marshal.GetHRForLastWin32Error());
        var state = Read(handle, identity);
        if (state.InSyncState != 1 || state.ModifiedDataSize != 0 || state.PinState == CloudFilesInterop.PinStatePinned) return false;
        if (!CloudFilesInterop.GetFileStandardInfo(handle, 1, out var standard, (uint)Marshal.SizeOf<CloudFilesInterop.FileStandardInfo>()) ||
            !CloudFilesInterop.GetFileBasicInfo(handle, 0, out var basic, (uint)Marshal.SizeOf<CloudFilesInterop.FileBasicInfo>()))
            throw new IOException("cloud.cache.metadata_unavailable", Marshal.GetHRForLastWin32Error());
        if (standard.Directory != 0 || standard.DeletePending != 0 || standard.EndOfFile < 0) return false;
        // VERIFY_IN_SYNC | MARK_IN_SYNC | DEHYDRATE；只确认本来已同步的内容，不把编辑标成已保存。
        CloudFilesInterop.ThrowIfFailed(CloudFilesInterop.CfUpdatePlaceholder(handle,
            new() { FileSize = standard.EndOfFile, BasicInfo = new() { FileAttributes = basic.FileAttributes | 1u } },
            IntPtr.Zero, 0, IntPtr.Zero, 0, 7, IntPtr.Zero, IntPtr.Zero), "CfUpdatePlaceholder.release-cache");
        return Read(handle, identity).OnDiskDataSize == 0;
    }

    internal static bool AcknowledgeRelocation(string localPath, string identity, bool directory, long length)
    {
        // NAS 名称已核查后，仅确认未改变的数据；不请求 READ_DATA，不把未下载内容强制拉取。
        using var handle = CloudFilesInterop.CreateFile(localPath, 0x50080, 0, IntPtr.Zero, CloudFilesInterop.OpenExisting,
            CloudFilesInterop.FileFlagOpenReparsePoint | (directory ? CloudFilesInterop.FileFlagBackupSemantics : 0), IntPtr.Zero);
        if (handle.IsInvalid) throw new IOException("cloud.relocate.local_unavailable", Marshal.GetHRForLastWin32Error());
        var state = Read(handle, identity);
        if (!CloudFilesInterop.GetFileStandardInfo(handle, 1, out var standard, (uint)Marshal.SizeOf<CloudFilesInterop.FileStandardInfo>()))
            throw new IOException("cloud.writeback.metadata_unavailable", Marshal.GetHRForLastWin32Error());
        if ((standard.Directory != 0) != directory || standard.DeletePending != 0) throw new InvalidDataException("cloud.relocate.local_unverified");
        if (state.ModifiedDataSize != 0 || !directory && standard.EndOfFile != length) return false;
        CloudFilesInterop.ThrowIfFailed(CloudFilesInterop.CfSetInSyncState(handle, 1, 0, IntPtr.Zero), "CfSetInSyncState.relocated");
        return Read(handle, identity).InSyncState == 1;
    }

    internal static (bool Directory, bool Undelete) ReadDeleteRequest(IntPtr parameters)
    {
        if (parameters == IntPtr.Zero || Marshal.ReadInt32(parameters) < 12) throw new InvalidDataException("cloud.delete.invalid_callback");
        var flags = unchecked((uint)Marshal.ReadInt32(parameters, 8));
        if ((flags & ~3u) != 0) throw new InvalidDataException("cloud.delete.invalid_callback");
        return ((flags & 1) != 0, (flags & 2) != 0);
    }

    internal static void RequireSynchronized(string localPath, string expectedIdentity, bool directory)
    {
        using var handle = CloudFilesInterop.CreateFile(localPath, 0x80, CloudFilesInterop.FileShareReadWriteDelete, IntPtr.Zero,
            CloudFilesInterop.OpenExisting, CloudFilesInterop.FileFlagOpenReparsePoint | (directory ? CloudFilesInterop.FileFlagBackupSemantics : 0), IntPtr.Zero);
        if (handle.IsInvalid) throw new IOException("cloud.delete.local_unavailable", Marshal.GetHRForLastWin32Error());
        var state = Read(handle, expectedIdentity);
        if (state.InSyncState != 1 || state.ModifiedDataSize != 0) throw new InvalidOperationException("cloud.sync.pending_changes");
    }

    internal static void BindRenamedLocalFile(string localPath, string expectedIdentity)
    {
        // 只绑定本地身份，不声明上传成功，不释放文件内容。独占期间拒绝编辑器替换或写入。
        using var handle = CloudFilesInterop.CreateFile(localPath, 0x50080, 0, IntPtr.Zero, CloudFilesInterop.OpenExisting,
            CloudFilesInterop.FileFlagOpenReparsePoint, IntPtr.Zero);
        if (handle.IsInvalid) throw new IOException("cloud.writeback.file_busy", Marshal.GetHRForLastWin32Error());
        if (!CloudFilesInterop.GetFileBasicInfo(handle, 0, out var basic, (uint)Marshal.SizeOf<CloudFilesInterop.FileBasicInfo>()) ||
            !CloudFilesInterop.GetFileStandardInfo(handle, 1, out var standard, (uint)Marshal.SizeOf<CloudFilesInterop.FileStandardInfo>()))
            throw new IOException("cloud.writeback.metadata_unavailable", Marshal.GetHRForLastWin32Error());
        if (standard.Directory != 0 || standard.DeletePending != 0 || standard.NumberOfLinks != 1)
            throw new InvalidDataException("cloud.relocate.local_unverified");
        if ((basic.FileAttributes & 0x400) != 0) { _ = Read(handle, expectedIdentity); return; }
        var identity = Encoding.UTF8.GetBytes(expectedIdentity);
        CloudFilesInterop.ThrowIfFailed(CloudFilesInterop.CfConvertToPlaceholder(handle, identity, (uint)identity.Length,
            0, IntPtr.Zero, IntPtr.Zero), "CfConvertToPlaceholder.renamed");
        var state = Read(handle, expectedIdentity);
        if (state.InSyncState == 1 || state.OnDiskDataSize < standard.EndOfFile)
            throw new InvalidDataException("cloud.relocate.local_unverified");
    }

    internal static string ReadIdentity(string localPath)
    {
        using var handle = CloudFilesInterop.CreateFile(localPath, 0x80, CloudFilesInterop.FileShareReadWriteDelete,
            IntPtr.Zero, CloudFilesInterop.OpenExisting, CloudFilesInterop.FileFlagOpenReparsePoint | CloudFilesInterop.FileFlagBackupSemantics, IntPtr.Zero);
        if (handle.IsInvalid) throw new IOException("cloud.relocate.local_unavailable", Marshal.GetHRForLastWin32Error());
        var buffer = Marshal.AllocHGlobal(4160);
        try
        {
            CloudFilesInterop.ThrowIfFailed(CloudFilesInterop.CfGetPlaceholderInfo(handle, 1, buffer, 4160, out var returned), "CfGetPlaceholderInfo.identity");
            var length = Marshal.ReadInt32(buffer, 56);
            if (length <= 0 || length > 4096 || returned < 60 + length) throw new InvalidDataException("cloud.sync.placeholder_identity");
            var bytes = new byte[length]; Marshal.Copy(IntPtr.Add(buffer, 60), bytes, 0, length);
            return new UTF8Encoding(false, true).GetString(bytes);
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    internal static bool AcknowledgeCreatedDirectory(string localPath, string expectedIdentity)
    {
        // 不独占子项内容；目录句柄不共享 DELETE，转换期间不能把目录移到另一位置。
        using var handle = CloudFilesInterop.CreateFile(localPath, 0x50080, 3, IntPtr.Zero, CloudFilesInterop.OpenExisting,
            CloudFilesInterop.FileFlagOpenReparsePoint | CloudFilesInterop.FileFlagBackupSemantics, IntPtr.Zero);
        if (handle.IsInvalid) throw new IOException("cloud.writeback.file_busy", Marshal.GetHRForLastWin32Error());
        if (!CloudFilesInterop.GetFileBasicInfo(handle, 0, out var basic, (uint)Marshal.SizeOf<CloudFilesInterop.FileBasicInfo>()) ||
            !CloudFilesInterop.GetFileStandardInfo(handle, 1, out var standard, (uint)Marshal.SizeOf<CloudFilesInterop.FileStandardInfo>()))
            throw new IOException("cloud.writeback.metadata_unavailable", Marshal.GetHRForLastWin32Error());
        if (standard.Directory == 0 || standard.DeletePending != 0) return false;
        if ((basic.FileAttributes & 0x400) != 0)
        {
            _ = Read(handle, expectedIdentity);
            CloudFilesInterop.ThrowIfFailed(CloudFilesInterop.CfSetInSyncState(handle, 1, 0, IntPtr.Zero), "CfSetInSyncState.directory");
        }
        else
        {
            var identity = Encoding.UTF8.GetBytes(expectedIdentity);
            CloudFilesInterop.ThrowIfFailed(CloudFilesInterop.CfConvertToPlaceholder(handle, identity, (uint)identity.Length,
                5, IntPtr.Zero, IntPtr.Zero), "CfConvertToPlaceholder.directory"); // 已同步并允许后续按需列目录。
        }
        return Read(handle, expectedIdentity).InSyncState == 1;
    }

    internal static bool IsModified(string localPath, string expectedIdentity)
    {
        using var handle = CloudFilesInterop.CreateFile(localPath, 0x80, CloudFilesInterop.FileShareReadWriteDelete,
            IntPtr.Zero, CloudFilesInterop.OpenExisting, CloudFilesInterop.FileFlagOpenReparsePoint, IntPtr.Zero);
        if (handle.IsInvalid) throw new IOException("cloud.writeback.file_busy", Marshal.GetHRForLastWin32Error());
        if (!CloudFilesInterop.GetFileBasicInfo(handle, 0, out var basic, (uint)Marshal.SizeOf<CloudFilesInterop.FileBasicInfo>()))
            throw new IOException("cloud.writeback.metadata_unavailable", Marshal.GetHRForLastWin32Error());
        if ((basic.FileAttributes & 0x10) != 0) return false;
        if ((basic.FileAttributes & 0x400) == 0) return true; // 已登记位置的编辑器覆盖保存。
        var state = Read(handle, expectedIdentity);
        return state.ModifiedDataSize != 0 || state.InSyncState != 1;
    }

    internal static bool AcknowledgeSavedContent(string localPath, string expectedIdentity, long length, string hash)
    {
        // 先检查占位完整性，防止仅为确认上传结果而触发隐式下载。
        using (var metadata = CloudFilesInterop.CreateFile(localPath, 0x80, CloudFilesInterop.FileShareReadWriteDelete,
            IntPtr.Zero, CloudFilesInterop.OpenExisting, CloudFilesInterop.FileFlagOpenReparsePoint, IntPtr.Zero))
        {
            if (metadata.IsInvalid) throw new IOException("cloud.writeback.file_busy", Marshal.GetHRForLastWin32Error());
            if (!CloudFilesInterop.GetFileBasicInfo(metadata, 0, out var basic, (uint)Marshal.SizeOf<CloudFilesInterop.FileBasicInfo>()))
                throw new IOException("cloud.writeback.metadata_unavailable", Marshal.GetHRForLastWin32Error());
            if ((basic.FileAttributes & 0x10) != 0) return false;
            if ((basic.FileAttributes & 0x400) != 0 && Read(metadata, expectedIdentity).OnDiskDataSize < length) return false;
        }
        // 同一句柄持有读取与 WRITE_DAC，拒绝并行写入/替换；不修改 ACL，不截断文件。
        using var handle = CloudFilesInterop.CreateFile(localPath, 0x40081, 0, IntPtr.Zero, CloudFilesInterop.OpenExisting,
            CloudFilesInterop.FileFlagOpenReparsePoint, IntPtr.Zero);
        if (handle.IsInvalid) throw new IOException("cloud.writeback.file_busy", Marshal.GetHRForLastWin32Error());
        if (!CloudFilesInterop.GetFileBasicInfo(handle, 0, out var currentBasic, (uint)Marshal.SizeOf<CloudFilesInterop.FileBasicInfo>()))
            throw new IOException("cloud.writeback.metadata_unavailable", Marshal.GetHRForLastWin32Error());
        var placeholder = (currentBasic.FileAttributes & 0x400) != 0;
        if (placeholder) _ = Read(handle, expectedIdentity);
        using var content = new FileStream(handle, FileAccess.Read, 65536, isAsync: false);
        if (content.Length != length || Convert.ToHexString(SHA256.HashData(content)) != hash) return false;
        if (placeholder) CloudFilesInterop.ThrowIfFailed(CloudFilesInterop.CfSetInSyncState(handle, 1, 0, IntPtr.Zero), "CfSetInSyncState.saved");
        else
        {
            var identity = Encoding.UTF8.GetBytes(expectedIdentity);
            CloudFilesInterop.ThrowIfFailed(CloudFilesInterop.CfConvertToPlaceholder(handle, identity, (uint)identity.Length,
                1, IntPtr.Zero, IntPtr.Zero), "CfConvertToPlaceholder.saved"); // MARK_IN_SYNC，不释放内容。
        }
        var verified = Read(handle, expectedIdentity);
        if (verified.InSyncState != 1 || verified.ModifiedDataSize != 0) throw new IOException("cloud.writeback.local_result_unknown");
        return true;
    }

    internal static Stream OpenEditedContent(string localPath, string expectedIdentity)
    {
        // 先用属性句柄拒绝不完整占位，避免申请读取权限本身触发隐式下载。
        using (var metadata = CloudFilesInterop.CreateFile(localPath, 0x80, CloudFilesInterop.FileShareReadWriteDelete,
            IntPtr.Zero, CloudFilesInterop.OpenExisting, CloudFilesInterop.FileFlagOpenReparsePoint, IntPtr.Zero))
        {
            if (metadata.IsInvalid) throw new IOException("cloud.writeback.file_busy", Marshal.GetHRForLastWin32Error());
            ValidateEditedContent(metadata, expectedIdentity);
        }
        var handle = CloudFilesInterop.CreateFile(localPath, CloudFilesInterop.GenericRead, 1, IntPtr.Zero,
            CloudFilesInterop.OpenExisting, CloudFilesInterop.FileFlagOpenReparsePoint, IntPtr.Zero);
        try
        {
            if (handle.IsInvalid) throw new IOException("cloud.writeback.file_busy", Marshal.GetHRForLastWin32Error());
            ValidateEditedContent(handle, expectedIdentity);
            // 只接受本映射的已完整落地修改；share-read 拒绝仍在写入的编辑器，也不沿任意重解析点读取。
            return new FileStream(handle, FileAccess.Read, 65536, isAsync: false);
        }
        catch { handle.Dispose(); throw; }
    }

    private static void ValidateEditedContent(SafeFileHandle handle, string expectedIdentity)
    {
        var state = Read(handle, expectedIdentity);
        if (!CloudFilesInterop.GetFileStandardInfo(handle, 1, out var standard, (uint)Marshal.SizeOf<CloudFilesInterop.FileStandardInfo>()))
            throw new IOException("cloud.writeback.metadata_unavailable", Marshal.GetHRForLastWin32Error());
        if (standard.Directory != 0 || standard.DeletePending != 0 || standard.EndOfFile < 0 ||
            state.OnDiskDataSize < standard.EndOfFile || state.ModifiedDataSize == 0 && state.InSyncState == 1)
            throw new InvalidDataException("cloud.writeback.no_complete_edit");
    }

    internal static void PreserveLocallyReadOnly(string localPath, string expectedIdentity)
    {
        using var handle = CloudFilesInterop.CreateFile(localPath, 0x10180, 0, IntPtr.Zero, CloudFilesInterop.OpenExisting,
            CloudFilesInterop.FileFlagOpenReparsePoint, IntPtr.Zero);
        if (handle.IsInvalid) throw new IOException("cloud.writeback.file_busy", Marshal.GetHRForLastWin32Error());
        if (!CloudFilesInterop.GetFileBasicInfo(handle, 0, out var basic, (uint)Marshal.SizeOf<CloudFilesInterop.FileBasicInfo>()) ||
            !CloudFilesInterop.GetFileStandardInfo(handle, 1, out var standard, (uint)Marshal.SizeOf<CloudFilesInterop.FileStandardInfo>()))
            throw new IOException("cloud.writeback.metadata_unavailable", Marshal.GetHRForLastWin32Error());
        if (standard.Directory != 0 || standard.DeletePending != 0) throw new InvalidDataException("cloud.writeback.invalid_item");
        if ((basic.FileAttributes & 0x400) != 0 && Read(handle, expectedIdentity).OnDiskDataSize < standard.EndOfFile)
            throw new InvalidDataException("cloud.writeback.incomplete_content");
        var attributes = new CloudFilesInterop.FileBasicInfo { FileAttributes = basic.FileAttributes | 1u };
        // 仅恢复只读属性；保留本地不等于保存到 NAS，不调用 MARK_IN_SYNC。
        if (!CloudFilesInterop.SetFileBasicInfo(handle, 0, attributes, (uint)Marshal.SizeOf<CloudFilesInterop.FileBasicInfo>()))
            throw new IOException("cloud.writeback.protection_failed", Marshal.GetHRForLastWin32Error());
    }

    internal static void SetWritable(string localPath, string expectedIdentity, bool writable)
    {
        // DELETE 仅用于 share-none 的排他性检查，不调用删除；不请求 READ_DATA，避免隐式下载。
        using var handle = CloudFilesInterop.CreateFile(localPath, 0x50080, 0, IntPtr.Zero, CloudFilesInterop.OpenExisting,
            CloudFilesInterop.FileFlagOpenReparsePoint, IntPtr.Zero);
        if (handle.IsInvalid) throw new IOException("cloud.writeback.file_busy", Marshal.GetHRForLastWin32Error());
        var state = Read(handle, expectedIdentity);
        if (state.ModifiedDataSize != 0 || state.InSyncState != 1) throw new InvalidDataException("cloud.writeback.local_changes");
        if (!CloudFilesInterop.GetFileStandardInfo(handle, 1, out var standard, (uint)Marshal.SizeOf<CloudFilesInterop.FileStandardInfo>()) ||
            !CloudFilesInterop.GetFileBasicInfo(handle, 0, out var basic, (uint)Marshal.SizeOf<CloudFilesInterop.FileBasicInfo>()))
            throw new IOException("cloud.writeback.metadata_unavailable", Marshal.GetHRForLastWin32Error());
        if (standard.Directory != 0 || standard.DeletePending != 0 || standard.EndOfFile < 0)
            throw new InvalidDataException("cloud.writeback.invalid_item");
        var attributes = writable ? basic.FileAttributes & ~1u : basic.FileAttributes | 1u;
        if (attributes == basic.FileAttributes) return;
        if (attributes == 0) attributes = 0x80; // FILE_ATTRIBUTE_NORMAL，不把 0 当作“不修改”。
        CloudFilesInterop.ThrowIfFailed(CloudFilesInterop.CfUpdatePlaceholder(handle,
            new() { FileSize = standard.EndOfFile, BasicInfo = new() { FileAttributes = attributes } }, IntPtr.Zero, 0,
            IntPtr.Zero, 0, 3, IntPtr.Zero, IntPtr.Zero), "CfUpdatePlaceholder.writable");
    }

    internal static bool Remove(string localPath, string expectedIdentity, bool directory, CloudFileLocalRemovalGate gate, bool confirmedDeletion = false)
    {
        // DELETE + READ_ATTRIBUTES 已参与共享检查；不请求 READ_DATA，避免为远端已移除项触发下载。
        using var handle = CloudFilesInterop.CreateFile(localPath, 0x00010080, 0, IntPtr.Zero,
            CloudFilesInterop.OpenExisting, CloudFilesInterop.FileFlagOpenReparsePoint |
            (directory ? CloudFilesInterop.FileFlagBackupSemantics : 0), IntPtr.Zero);
        if (handle.IsInvalid)
        {
            var error = Marshal.GetLastWin32Error();
            if (error is 2 or 3) return true;
            throw new IOException("cloud.remove.unavailable", unchecked((int)(0x80070000u | (uint)error)));
        }
        var state = Read(handle, expectedIdentity);
        if (state.InSyncState != 1 || state.ModifiedDataSize != 0 || state.PinState == CloudFilesInterop.PinStatePinned && !confirmedDeletion)
            return false;
        using var permission = gate.Authorize(state, expectedIdentity);
        try
        {
            const uint disposition = 0x11; // DELETE | IGNORE_READONLY_ATTRIBUTE；不清除属性，不递归，不允许 POSIX 绕过占用。
            if (!CloudFilesInterop.SetFileInformationByHandle(handle, 21, disposition, sizeof(uint)))
                throw new IOException("cloud.remove.failed", Marshal.GetHRForLastWin32Error());
        }
        finally { handle.Dispose(); } // 授权保留到删除句柄关闭，覆盖系统延迟通知。
        if (File.Exists(localPath) || Directory.Exists(localPath)) throw new IOException("cloud.remove.unverified");
        return true;
    }

    internal static CloudFilesInterop.PlaceholderStandardInfo Read(SafeFileHandle handle, string expectedIdentity)
    {
        var identity = Encoding.UTF8.GetBytes(expectedIdentity);
        var capacity = checked(64 + identity.Length);
        var buffer = Marshal.AllocHGlobal(capacity);
        try
        {
            CloudFilesInterop.ThrowIfFailed(CloudFilesInterop.CfGetPlaceholderInfo(handle, 1, buffer,
                (uint)capacity, out var returnedLength), "CfGetPlaceholderInfo");
            if (returnedLength < 60) throw new InvalidDataException("cloud.sync.placeholder_identity");
            var result = Marshal.PtrToStructure<CloudFilesInterop.PlaceholderStandardInfo>(buffer);
            if (result.FileIdentityLength != identity.Length || returnedLength < 60 + identity.Length)
                throw new InvalidDataException("cloud.sync.placeholder_identity");
            var actualIdentity = new byte[identity.Length];
            Marshal.Copy(IntPtr.Add(buffer, 60), actualIdentity, 0, actualIdentity.Length);
            if (!actualIdentity.AsSpan().SequenceEqual(identity)) throw new InvalidDataException("cloud.sync.placeholder_identity");
            return result;
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    // 返回值指示调用方在版本落盘、独占句柄释放后重新获取固定离线内容。
    internal static bool Update(string localPath, string expectedIdentity, CloudFilesInterop.FileSystemMetadata metadata, bool invalidate)
    {
        if (Directory.Exists(localPath)) throw new InvalidDataException("cloud.refresh.type_changed");
        // 只读占位文件不能用 FILE_WRITE_DATA 打开。官方也允许 WRITE_DAC；不修改 ACL 或移除只读属性。
        // 同时请求 READ_DATA，确保 share-none 参与数据句柄共享检查，而不只是属性查询句柄。
        using var handle = CloudFilesInterop.CreateFile(localPath, 0x00040081, 0, IntPtr.Zero,
            CloudFilesInterop.OpenExisting, CloudFilesInterop.FileFlagOpenReparsePoint, IntPtr.Zero);
        if (handle.IsInvalid) throw new IOException("cloud.refresh.file_busy", Marshal.GetHRForLastWin32Error());
        var state = Read(handle, expectedIdentity);
        if (state.InSyncState != 1 || state.ModifiedDataSize != 0)
            throw new InvalidDataException("cloud.refresh.local_changes");
        if (invalidate)
        {
            if (!CloudFilesInterop.GetFileBasicInfo(handle, 0, out var currentBasic, (uint)Marshal.SizeOf<CloudFilesInterop.FileBasicInfo>()))
                throw new IOException("cloud.refresh.metadata_unavailable", Marshal.GetHRForLastWin32Error());
            metadata.BasicInfo.FileAttributes = currentBasic.FileAttributes | 1u;
        }
        var wasPinned = state.PinState == CloudFilesInterop.PinStatePinned;
        var unpinned = false;
        try
        {
            if (invalidate && wasPinned)
            {
                CloudFilesInterop.ThrowIfFailed(CloudFilesInterop.CfSetPinState(handle.DangerousGetHandle(),
                    CloudFilesInterop.PinStateUnpinned, 0, IntPtr.Zero), "CfSetPinState");
                unpinned = true;
            }
            // VERIFY_IN_SYNC | MARK_IN_SYNC；失效时加 DEHYDRATE。独占句柄只覆盖这段短时本地操作。
            CloudFilesInterop.ThrowIfFailed(CloudFilesInterop.CfUpdatePlaceholder(handle, metadata, IntPtr.Zero, 0,
                IntPtr.Zero, 0, invalidate ? 7u : 3u, IntPtr.Zero, IntPtr.Zero), "CfUpdatePlaceholder");
        }
        finally
        {
            if (unpinned) CloudFilesInterop.ThrowIfFailed(CloudFilesInterop.CfSetPinState(handle.DangerousGetHandle(),
                CloudFilesInterop.PinStatePinned, 0, IntPtr.Zero), "CfSetPinState");
        }
        // 上次刷新可能已切换版本，但随后离线下载被取消；再次刷新仍须补齐缺少的离线内容。
        return wasPinned && metadata.FileSize > 0 && (invalidate || state.OnDiskDataSize < metadata.FileSize);
    }
}
