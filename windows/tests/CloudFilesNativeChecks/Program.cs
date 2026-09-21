using System.Runtime.InteropServices;
using System.Text;
using LanStash.App.CloudDrive;
using LanStash.Domain;
using System.Diagnostics;

// 显式运行的隔离系统接口检查，不读取应用配置、不连接 NAS、不混入常规单元测试。
Console.OutputEncoding = Encoding.UTF8;
if (args is ["--bind-control", var controlRoot])
{
    var target = Path.GetFullPath(controlRoot); var name = Path.GetFileName(target);
    if (Path.GetDirectoryName(target) != Path.GetFullPath(Path.GetTempPath()).TrimEnd(Path.DirectorySeparatorChar) ||
        !name.StartsWith("lanstash-shell-check-", StringComparison.Ordinal) || !Guid.TryParseExact(name[21..], "N", out _) ||
        !File.Exists(target + "-test-marker") || File.ReadAllText(target + "-test-marker") != name) return 2;
    ShellRecycle.Request(Path.Combine(target, "control.bin"), performDelete: false);
    return 0;
}
if (args is ["--isolated-shell-binding"])
{
    var control = Path.Combine(Path.GetTempPath(), "lanstash-shell-check-" + Guid.NewGuid().ToString("N"));
    Directory.CreateDirectory(control);
    await File.WriteAllTextAsync(control + "-test-marker", Path.GetFileName(control));
    await File.WriteAllTextAsync(Path.Combine(control, "control.bin"), "synthetic");
    try
    {
        var start = new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true };
        start.ArgumentList.Add("--bind-control"); start.ArgumentList.Add(control);
        using var child = Process.Start(start)!; var output = child.StandardOutput.ReadToEndAsync();
        try { await child.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(30)); }
        catch (TimeoutException)
        {
            if (!child.HasExited) { child.Kill(); await child.WaitForExitAsync(); }
            Console.WriteLine(await output); Console.WriteLine("FAIL：普通非云文件的 Shell 绑定同样超时，未调用删除。"); return 1;
        }
        Console.WriteLine(await output);
        Require(child.ExitCode == 0 && File.ReadAllText(Path.Combine(control, "control.bin")) == "synthetic", "非云文件 Shell 只读绑定对照");
        return 0;
    }
    finally
    {
        if (Directory.EnumerateFileSystemEntries(control).Any(path => Path.GetFileName(path) != "control.bin")) throw new IOException("合成对照目录出现未知内容。");
        File.Delete(Path.Combine(control, "control.bin")); Directory.Delete(control, recursive: false); File.Delete(control + "-test-marker");
    }
}
if (args.Length is 2 or 3 && args[0] == "--attempt-external-rename")
{
    if (args.Length == 3 && args[2] != "--recycle") return 2;
    var renameRoot = args[1];
    var target = Path.GetFullPath(renameRoot); var name = Path.GetFileName(target);
    if (Path.GetDirectoryName(target) != Path.GetFullPath(Path.GetTempPath()).TrimEnd(Path.DirectorySeparatorChar) ||
        !name.StartsWith("lanstash-cf-check-", StringComparison.Ordinal) || !Guid.TryParseExact(name[18..], "N", out _) ||
        !File.Exists(target + "-test-marker") || File.ReadAllText(target + "-test-marker") != name) return 2;
    File.Move(Path.Combine(target, "external-source.bin"), Path.Combine(target, "external-target.bin"));
    using (var deleteHandle = CloudFilesInterop.CreateFile(Path.Combine(target, "remote-removed.bin"), 0x10080, 0, IntPtr.Zero,
        CloudFilesInterop.OpenExisting, CloudFilesInterop.FileFlagOpenReparsePoint, IntPtr.Zero))
    {
        if (deleteHandle.IsInvalid) return 3;
        const uint deniedDelete = 0x11;
        if (CloudFilesInterop.SetFileInformationByHandle(deleteHandle, 21, deniedDelete, sizeof(uint))) return 1;
    }
    if (args.Length != 3) return 0;
    Console.WriteLine("合成子进程：开始文件回收站请求。");
    ShellRecycle.Request(Path.Combine(target, "recycle-file.bin"));
    Console.WriteLine("合成子进程：开始目录回收站请求。");
    ShellRecycle.Request(Path.Combine(target, "recycle-folder"));
    Console.WriteLine("合成子进程：Shell 请求返回。");
    return File.Exists(Path.Combine(target, "recycle-file.bin")) && Directory.Exists(Path.Combine(target, "recycle-folder")) ? 0 : 4;
}
if (args is ["--attempt-external-delete", var deleteTarget])
{
    var target = Path.GetFullPath(deleteTarget);
    var parent = Path.GetDirectoryName(target)!;
    var name = Path.GetFileName(parent);
    if (Path.GetFileName(target) != "remote-removed.bin" ||
        Path.GetDirectoryName(parent) != Path.GetFullPath(Path.GetTempPath()).TrimEnd(Path.DirectorySeparatorChar) ||
        !name.StartsWith("lanstash-cf-check-", StringComparison.Ordinal) || !Guid.TryParseExact(name[18..], "N", out _) ||
        !File.Exists(parent + "-test-marker") || File.ReadAllText(parent + "-test-marker") != name) return 2;
    using var handle = CloudFilesInterop.CreateFile(target, 0x10080, 0, IntPtr.Zero, CloudFilesInterop.OpenExisting,
        CloudFilesInterop.FileFlagOpenReparsePoint, IntPtr.Zero);
    if (handle.IsInvalid) return 3;
    const uint disposition = 0x11;
    return CloudFilesInterop.SetFileInformationByHandle(handle, 21, disposition, sizeof(uint)) ? 1 : 0;
}
if (args is ["--cleanup-isolated-refresh", var cleanupRoot])
{
    var target = Path.GetFullPath(cleanupRoot);
    var prefix = "lanstash-cf-check-";
    if (Path.GetDirectoryName(target) != Path.GetFullPath(Path.GetTempPath()).TrimEnd(Path.DirectorySeparatorChar) ||
        !Path.GetFileName(target).StartsWith(prefix, StringComparison.Ordinal) ||
        !Guid.TryParseExact(Path.GetFileName(target)[prefix.Length..], "N", out _)) return 2;
    CleanupGeneratedRoot(target);
    return 0;
}
var checkShell = args.SequenceEqual(["--isolated-recycle"]);
if (!args.SequenceEqual(["--isolated-refresh"]) && !checkShell)
{
    Console.Error.WriteLine("请显式使用 --isolated-refresh 或 --isolated-recycle；仅创建并清理本次生成的临时同步根。");
    return 2;
}
var root = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "lanstash-cf-check-" + Guid.NewGuid().ToString("N")));
var file = Path.Combine(root, "synthetic.bin");
var createdNames = new List<string>();
var syncDirectory = root + "-sync";
var mapping = new DesktopDriveMapping(Guid.NewGuid(), Guid.NewGuid(), "Synthetic", DesktopDriveScope.Folder("/share"),
    DesktopDriveAccessMode.ReadOnly, DesktopDriveCachePolicy.Default, false, DateTimeOffset.UtcNow);
var registered = false;
var connected = false;
CloudFilesInterop.ConnectionKey connection = default;
CloudFilesInterop.Callback? deleteCallback = null;
CloudFilesInterop.Callback? renameCallback = null;
CloudFilesInterop.Callback? renamedCallback = null;
CloudFilesInterop.Callback? metadataCallback = null;
const string identity = "synthetic-placeholder";
try
{
    Directory.CreateDirectory(root);
    await File.WriteAllTextAsync(root + "-test-marker", Path.GetFileName(root));
    var registration = new CloudFilesInterop.SyncRegistration
    {
        StructSize = (uint)Marshal.SizeOf<CloudFilesInterop.SyncRegistration>(), ProviderName = "LanStash Synthetic Check",
        ProviderVersion = "1.0", ProviderId = Guid.NewGuid()
    };
    var policy = new CloudFilesInterop.SyncPolicies
    {
        StructSize = (uint)Marshal.SizeOf<CloudFilesInterop.SyncPolicies>(), Hydration = new() { Primary = 1 },
        Population = new() { Primary = 3 }, InSync = CloudFilesInterop.InSyncPolicyDefault // 合成目录已完整创建，没有 NAS 枚举回调。
    };
    CloudFilesInterop.ThrowIfFailed(CloudFilesInterop.CfRegisterSyncRoot(root, registration, policy,
        CloudFilesInterop.RegisterMarkRootInSync), "CfRegisterSyncRoot");
    registered = true;
    var name = Marshal.StringToHGlobalUni("synthetic.bin");
    var bytes = Encoding.UTF8.GetBytes(identity); var id = Marshal.AllocHGlobal(bytes.Length);
    try
    {
        Marshal.Copy(bytes, 0, id, bytes.Length);
        var placeholder = new CloudFilesInterop.PlaceholderCreateInfo
        {
            RelativeFileName = name, FileIdentity = id, FileIdentityLength = (uint)bytes.Length,
            Flags = CloudFilesInterop.PlaceholderMarkInSync,
            FileSystemMetadata = new() { FileSize = 8192, BasicInfo = new() { FileAttributes = 1 } }
        };
        var values = new[] { placeholder };
        CloudFilesInterop.ThrowIfFailed(CloudFilesInterop.CfCreatePlaceholders(root, values, 1, 0, out var processed), "CfCreatePlaceholders");
        Require(processed == 1 && values[0].Result >= 0, "创建合成占位文件");
    }
    finally { Marshal.FreeHGlobal(id); Marshal.FreeHGlobal(name); }
    CloudFilePlaceholderNative.Update(file, identity, new() { FileSize = 16384 }, true);
    Require(new FileInfo(file).Length == 16384 && (File.GetAttributes(file) & FileAttributes.ReadOnly) != 0,
        "只读占位文件更新大小且只读属性保留");
    CloudFilePlaceholderNative.SetWritable(file, identity, true);
    Require(new FileInfo(file).Length == 16384 && (File.GetAttributes(file) & FileAttributes.ReadOnly) == 0,
        "启用可编辑不截断文件");
    CloudFilePlaceholderNative.SetWritable(file, identity, false);
    Require(new FileInfo(file).Length == 16384 && (File.GetAttributes(file) & FileAttributes.ReadOnly) != 0,
        "恢复只读不截断文件");
    try { CloudFilePlaceholderNative.Update(file, new string('x', identity.Length), new() { FileSize = 1 }, true); throw new Exception("错误身份未被拒绝"); }
    catch (InvalidDataException) { Require(new FileInfo(file).Length == 16384, "错误身份不能更新另一个文件"); }
    using (var reader = CloudFilesInterop.CreateFile(file, CloudFilesInterop.GenericRead, CloudFilesInterop.FileShareReadWriteDelete,
        IntPtr.Zero, CloudFilesInterop.OpenExisting, CloudFilesInterop.FileFlagOpenReparsePoint, IntPtr.Zero))
    {
        Require(!reader.IsInvalid, "打开合成只读数据句柄");
        try { CloudFilePlaceholderNative.Update(file, identity, new() { FileSize = 1 }, true); throw new Exception("打开的文件未被独占检查拒绝"); }
        catch (IOException) { Require(new FileInfo(file).Length == 16384, "文件正被读取时不失效缓存"); }
    }
    using (var handle = Open(file))
        CloudFilesInterop.ThrowIfFailed(CloudFilesInterop.CfSetPinState(handle.DangerousGetHandle(), 1, 0, IntPtr.Zero), "CfSetPinState");
    Require(CloudFilePlaceholderNative.Update(file, identity, new() { FileSize = 4096 }, true), "固定离线内容要求重新获取");
    Require(CloudFilePlaceholderNative.Update(file, identity, new() { FileSize = 4096 }, false), "同版本缺少离线内容时仍要求补齐");
    using (var handle = Open(file))
    {
        Require(CloudFilePlaceholderNative.Read(handle, identity).PinState == 1, "固定离线偏好保留");
        CloudFilesInterop.ThrowIfFailed(CloudFilesInterop.CfSetInSyncState(handle, 0, 0, IntPtr.Zero), "CfSetInSyncState");
    }
    try { CloudFilePlaceholderNative.Update(file, identity, new() { FileSize = 1 }, true); throw new Exception("未同步文件未被拒绝"); }
    catch (InvalidDataException) { Require(new FileInfo(file).Length == 4096, "未同步文件拒绝更新且大小不变"); }
    var names = await new DesktopCloudDriveSyncStore(syncDirectory).RegisterLocalNamesAsync(mapping,
        new Dictionary<string, string>(), ["/share/Report.txt"]);
    CreateNamedPlaceholder(root, names["/share/Report.txt"], DesktopDriveItemIdentity.Identifier(mapping.Id, "/share/Report.txt")!);
    createdNames.Add(names["/share/Report.txt"]);
    var expanded = await new DesktopCloudDriveSyncStore(syncDirectory).RegisterLocalNamesAsync(mapping, names, ["/share/report.txt"]);
    CreateNamedPlaceholder(root, expanded["/share/report.txt"], DesktopDriveItemIdentity.Identifier(mapping.Id, "/share/report.txt")!);
    createdNames.Add(expanded["/share/report.txt"]);
    Require(expanded["/share/Report.txt"] == createdNames[0] && createdNames.Distinct(StringComparer.OrdinalIgnoreCase).Count() == 2,
        "大小写冲突分配不同占位且旧文件不改名");
    var restartedNames = await new DesktopCloudDriveSyncStore(syncDirectory).RegisterLocalNamesAsync(mapping,
        DesktopDriveWindowsNameCodec.BuildSafeSegments(expanded.Keys), expanded.Keys);
    foreach (var entry in restartedNames)
    {
        using var handle = Open(Path.Combine(root, entry.Value));
        _ = CloudFilePlaceholderNative.Read(handle, DesktopDriveItemIdentity.Identifier(mapping.Id, entry.Key)!);
    }
    Require(restartedNames.OrderBy(item => item.Key).SequenceEqual(expanded.OrderBy(item => item.Key)), "重启后名称与真实占位身份一致");
    var removalGate = new CloudFileLocalRemovalGate(); var acceptedDeletes = 0; var rejectedDeletes = 0; var validatedDeletes = 0; var guardedUserDeletes = 0;
    var shellEvents = new System.Collections.Concurrent.ConcurrentQueue<string>();
    deleteCallback = (in CloudFilesInterop.CallbackInfo info, IntPtr parameters) =>
    {
        var valid = false;
        try
        {
            var request = CloudFilePlaceholderNative.ReadDeleteRequest(parameters);
            valid = !request.Undelete;
            if (valid) { Interlocked.Increment(ref validatedDeletes); shellEvents.Enqueue(request.Directory ? "delete-directory" : "delete-file"); }
        }
        catch { /* 解析失败时拒绝，结束后由断言报告。 */ }
        var allowed = valid && removalGate.TryConsume(info);
        if (valid && !allowed)
        {
            try
            {
                var bytes = new byte[info.FileIdentityLength]; Marshal.Copy(info.FileIdentity, bytes, 0, bytes.Length);
                var itemIdentity = Encoding.UTF8.GetString(bytes);
                var relative = itemIdentity switch
                {
                    "synthetic-removal" => "remote-removed.bin",
                    "synthetic-recycle-file" => "recycle-file.bin",
                    "synthetic-recycle-folder" => "recycle-folder",
                    "synthetic-recycle-child" => Path.Combine("recycle-folder", "nested.bin"),
                    _ => throw new InvalidDataException("未知合成删除目标"),
                };
                using var handle = CloudFilesInterop.CreateFile(Path.Combine(root, relative), 0x80, CloudFilesInterop.FileShareReadWriteDelete,
                    IntPtr.Zero, CloudFilesInterop.OpenExisting, CloudFilesInterop.FileFlagOpenReparsePoint | CloudFilesInterop.FileFlagBackupSemantics, IntPtr.Zero);
                var state = CloudFilePlaceholderNative.Read(handle, itemIdentity);
                if (state.FileId == info.FileId && state.SyncRootFileId == info.SyncRootFileId && state.ModifiedDataSize == 0)
                    Interlocked.Increment(ref guardedUserDeletes);
            }
            catch { /* 失败由外部身份断言报告，不越过原生回调边界。 */ }
        }
        if (allowed) Interlocked.Increment(ref acceptedDeletes); else Interlocked.Increment(ref rejectedDeletes);
        var operation = new CloudFilesInterop.OperationInfo { StructSize = (uint)Marshal.SizeOf<CloudFilesInterop.OperationInfo>(),
            Type = CloudFilesInterop.OperationAckDelete, ConnectionKey = info.ConnectionKey, TransferKey = info.TransferKey, RequestKey = info.RequestKey };
        var response = new CloudFilesInterop.AcknowledgeParameters { ParamSize = (uint)Marshal.SizeOf<CloudFilesInterop.AcknowledgeParameters>(),
            CompletionStatus = allowed ? CloudFilesInterop.StatusSuccess : CloudFilesInterop.StatusAccessDenied };
        var pointer = Marshal.AllocHGlobal(Marshal.SizeOf<CloudFilesInterop.AcknowledgeParameters>());
        try { Marshal.StructureToPtr(response, pointer, false); _ = CloudFilesInterop.CfExecute(operation, pointer); }
        finally { Marshal.FreeHGlobal(pointer); }
    };
    var renameRequests = 0;
    var renameCompleted = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    renameCallback = (in CloudFilesInterop.CallbackInfo info, IntPtr parameters) =>
    {
        var status = CloudFilesInterop.StatusAccessDenied;
        try
        {
            var request = CloudFileRenamePaths.Read(info, parameters, root);
            if (request.Target == Path.Combine(root, "external-target.bin") && !request.Directory)
            { Interlocked.Increment(ref renameRequests); status = 0; }
        }
        catch
        {
            if (parameters != IntPtr.Zero && Marshal.ReadInt32(parameters) >= 24)
            {
                var value = Marshal.PtrToStructure<CloudFilesInterop.RenameCallbackParameters>(parameters);
                if ((value.Flags & 6) == 2) shellEvents.Enqueue((value.Flags & 1) != 0 ? "rename-outside-directory" : "rename-outside-file");
            }
        }
        var operation = new CloudFilesInterop.OperationInfo { StructSize = (uint)Marshal.SizeOf<CloudFilesInterop.OperationInfo>(),
            Type = CloudFilesInterop.OperationAckRename, ConnectionKey = info.ConnectionKey, TransferKey = info.TransferKey, RequestKey = info.RequestKey };
        var response = new CloudFilesInterop.AcknowledgeParameters { ParamSize = (uint)Marshal.SizeOf<CloudFilesInterop.AcknowledgeParameters>(), CompletionStatus = status };
        var pointer = Marshal.AllocHGlobal(Marshal.SizeOf<CloudFilesInterop.AcknowledgeParameters>());
        try { Marshal.StructureToPtr(response, pointer, false); _ = CloudFilesInterop.CfExecute(operation, pointer); }
        finally { Marshal.FreeHGlobal(pointer); }
    };
    renamedCallback = (in CloudFilesInterop.CallbackInfo info, IntPtr parameters) => renameCompleted.TrySetResult();
    metadataCallback = (in CloudFilesInterop.CallbackInfo info, IntPtr parameters) =>
    {
        shellEvents.Enqueue("fetch-placeholders");
        var operation = new CloudFilesInterop.OperationInfo { StructSize = (uint)Marshal.SizeOf<CloudFilesInterop.OperationInfo>(),
            Type = CloudFilesInterop.OperationTransferPlaceholders, ConnectionKey = info.ConnectionKey, TransferKey = info.TransferKey, RequestKey = info.RequestKey };
        var response = new CloudFilesInterop.TransferPlaceholdersParameters
        { ParamSize = (uint)Marshal.SizeOf<CloudFilesInterop.TransferPlaceholdersParameters>(), Flags = CloudFilesInterop.TransferPlaceholdersComplete, CompletionStatus = 0, PlaceholderTotalCount = 0 };
        var buffer = Marshal.AllocHGlobal(Marshal.SizeOf<CloudFilesInterop.TransferPlaceholdersParameters>());
        try { Marshal.StructureToPtr(response, buffer, false); _ = CloudFilesInterop.CfExecute(operation, buffer); }
        finally { Marshal.FreeHGlobal(buffer); }
    };
    CloudFilesInterop.ThrowIfFailed(CloudFilesInterop.CfConnectSyncRoot(root,
        [new() { Type = CloudFilesInterop.CallbackFetchPlaceholders, Callback = metadataCallback },
         new() { Type = CloudFilesInterop.CallbackNotifyDelete, Callback = deleteCallback },
         new() { Type = CloudFilesInterop.CallbackNotifyRename, Callback = renameCallback },
         new() { Type = CloudFilesInterop.CallbackNotifyRenameCompletion, Callback = renamedCallback }, new() { Type = CloudFilesInterop.CallbackNone }],
        IntPtr.Zero, CloudFilesInterop.ConnectRequireFullPath | CloudFilesInterop.ConnectRequireProcessInfo, out connection), "CfConnectSyncRoot");
    connected = true;
    var allShares = mapping with { Id = Guid.NewGuid(), Scope = DesktopDriveScope.AllShares };
    var allSharePath = Path.Combine(root, "all-shares-fixture");
    CreateNamedPlaceholder(root, "all-shares-fixture", DesktopDriveItemIdentity.Identifier(allShares.Id, "/all-shares-fixture")!, directory: true);
    var allShareFile = Path.Combine(allSharePath, "edit.txt"); await File.WriteAllTextAsync(allShareFile, "all-shares native edit");
    var allShareStore = new DesktopCloudDriveSyncStore(syncDirectory);
    await allShareStore.SetWritebackEnabledAsync(allShares, true, true);
    await allShareStore.RegisterLocalNamesAsync(allShares, new Dictionary<string, string>(), ["/all-shares-fixture", "/all-shares-fixture/edit.txt"]);
    await allShareStore.BindEmptyFileBaselineAsync(allShares, "/all-shares-fixture/edit.txt", DateTimeOffset.UnixEpoch);
    var allShareEdit = await allShareStore.CaptureMappedSaveAsync(allShares, Guid.NewGuid(), "/all-shares-fixture/edit.txt", allShareFile, root);
    await using (var content = await allShareStore.OpenContentAsync(allShares, allShareEdit.Id))
    using (var reader = new StreamReader(content))
        Require(await reader.ReadToEndAsync() == "all-shares native edit", "全部共享编辑按真实共享占位身份和完整路径捕获");
    Require(Directory.GetFiles(allSharePath).Length == 1, "合成共享目录完整枚举");
    CreateNamedPlaceholder(root, "external-source.bin", "synthetic-external-rename", size: 0);
    createdNames.Add("external-source.bin"); createdNames.Add("external-target.bin");
    CloudFilePlaceholderNative.SetWritable(Path.Combine(root, "external-source.bin"), "synthetic-external-rename", true);
    var cleanupName = "remote-removed.bin"; CreateNamedPlaceholder(root, cleanupName, "synthetic-removal", size: 0); createdNames.Add(cleanupName);
    if (checkShell)
    {
        CreateNamedPlaceholder(root, "recycle-file.bin", "synthetic-recycle-file", size: 0); createdNames.Add("recycle-file.bin");
        CreateNamedPlaceholder(root, "recycle-folder", "synthetic-recycle-folder", directory: true);
        CreateNamedPlaceholder(Path.Combine(root, "recycle-folder"), "nested.bin", "synthetic-recycle-child", size: 0);
    }
    var renameChildInfo = new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true };
    renameChildInfo.ArgumentList.Add("--attempt-external-rename"); renameChildInfo.ArgumentList.Add(root);
    if (checkShell) renameChildInfo.ArgumentList.Add("--recycle");
    using (var renameChild = Process.Start(renameChildInfo) ?? throw new InvalidOperationException("无法启动独立改名检查"))
    {
        var childOutput = renameChild.StandardOutput.ReadToEndAsync();
        try { await renameChild.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(30)); }
        catch { if (!renameChild.HasExited) { renameChild.Kill(); await renameChild.WaitForExitAsync(); } Console.WriteLine(await childOutput); Console.WriteLine($"合成通知：rename={renameRequests}; " + string.Join(",", shellEvents.GroupBy(item => item).Select(group => group.Key + "=" + group.Count()))); throw; }
        if (checkShell) { Console.WriteLine(await childOutput); Console.WriteLine("合成 Shell 通知：" + string.Join(",", shellEvents.GroupBy(item => item).Select(group => group.Key + "=" + group.Count()))); }
        Require(renameChild.ExitCode == 0 && renameRequests == 1 && (checkShell ? rejectedDeletes >= 1 : rejectedDeletes == 1) && File.Exists(Path.Combine(root, cleanupName)),
            "同一外部进程改名通过且删除回调仍拒绝");
        Require(validatedDeletes == acceptedDeletes + rejectedDeletes, "真实删除通知通过生产参数解析器");
        Require(guardedUserDeletes == rejectedDeletes, "Shell 删除前原身份与未修改数据保护可验证");
        if (checkShell)
        {
            Require(shellEvents.Count(item => item == "delete-file") >= 2 || shellEvents.Contains("rename-outside-file"), "回收站文件请求实际到达同步提供方");
            Require(shellEvents.Contains("delete-directory") || shellEvents.Contains("rename-outside-directory"), "回收站目录请求实际到达同步提供方");
            Require(shellEvents.Count(item => item == "fetch-placeholders") <= 4, "目录完成标志阻止重复枚举循环");
            Require(CloudFilePlaceholderNative.AcknowledgeRelocation(Path.Combine(root, "recycle-file.bin"), "synthetic-recycle-file", false, 0) &&
                CloudFilePlaceholderNative.AcknowledgeRelocation(Path.Combine(root, "recycle-folder", "nested.bin"), "synthetic-recycle-child", false, 0),
                "回收站拒绝后的元数据状态可在内容核对后恢复");
        }
        await renameCompleted.Task.WaitAsync(TimeSpan.FromSeconds(5));
        using var renamed = Open(Path.Combine(root, "external-target.bin"));
        _ = CloudFilePlaceholderNative.Read(renamed, "synthetic-external-rename");
        Require(!File.Exists(Path.Combine(root, "external-source.bin")), "改名完成通知后目标保留原身份");
    }
    CloudFilePlaceholderNative.Remove(Path.Combine(root, cleanupName), "synthetic-removal", false, removalGate);
    Require(!File.Exists(Path.Combine(root, cleanupName)) && acceptedDeletes <= 1 && (checkShell ? rejectedDeletes >= 1 : rejectedDeletes == 1),
        "核查后的内部清理完成且外部删除仍拒绝");
    Require(!CloudFilePlaceholderNative.Remove(file, identity, false, removalGate) && File.Exists(file), "保留未同步或固定离线内容");
    var pinnedDeletePath = Path.Combine(root, "external-target.bin");
    var probePath = Path.Combine(root, "replacement.bin"); createdNames.Add("replacement.bin");
    await File.WriteAllTextAsync(probePath, "synthetic renamed edit");
    CloudFilePlaceholderNative.BindRenamedLocalFile(probePath, "synthetic-replacement");
    Require(!CloudFilePlaceholderNative.AcknowledgeRelocation(probePath, "synthetic-replacement", false, 22) &&
        CloudFilePlaceholderNative.IsModified(probePath, "synthetic-replacement"), "同长度本地编辑不能被改名确认标记为已同步");
    var probeHash = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(Encoding.UTF8.GetBytes("synthetic renamed edit")));
    Require(CloudFilePlaceholderNative.AcknowledgeSavedContent(probePath, "synthetic-replacement", 22, probeHash), "建立已保存的合成内容基线");
    File.SetAttributes(probePath, File.GetAttributes(probePath) | FileAttributes.Hidden);
    Require(!CloudFilePlaceholderNative.IsModified(probePath, "synthetic-replacement"), "本地隐藏属性不触发虚假的内容上传");
    using (var editor = new FileStream(probePath, FileMode.Open, FileAccess.Write, FileShare.Read)) editor.WriteByte(88);
    Require(CloudFilePlaceholderNative.IsModified(probePath, "synthetic-replacement") &&
        !CloudFilePlaceholderNative.AcknowledgeRelocation(probePath, "synthetic-replacement", false, 22), "默认策略下真实原位编辑仍未同步且不能被改名确认覆盖");
    File.SetAttributes(probePath, File.GetAttributes(probePath) & ~FileAttributes.Hidden);
    CreateNamedPlaceholder(root, "cold.bin", "synthetic-cold", size: 4096); createdNames.Add("cold.bin"); createdNames.Add("cold-renamed.bin");
    var coldTarget = Path.Combine(root, "cold-renamed.bin"); File.Move(Path.Combine(root, "cold.bin"), coldTarget);
    Require(!CloudFilePlaceholderNative.AcknowledgeRelocation(coldTarget, "synthetic-cold", false, 4095), "大小不一致不能确认改名后的内容状态");
    Require(CloudFilePlaceholderNative.AcknowledgeRelocation(coldTarget, "synthetic-cold", false, 4096), "未下载文件可以确认已核查的改名");
    using (var cold = Open(coldTarget)) Require(CloudFilePlaceholderNative.Read(cold, "synthetic-cold").OnDiskDataSize == 0,
        "改名确认没有隐式下载或分配文件内容");
    Require(CloudFilePlaceholderNative.AcknowledgeRelocation(pinnedDeletePath, "synthetic-external-rename", false, 0), "生产改名确认恢复仅元数据变化的同步状态");
    using (var handle = Open(pinnedDeletePath))
    {
        Require(CloudFilePlaceholderNative.Read(handle, "synthetic-external-rename").InSyncState == 1,
            "改名完成后无需重新上传原内容");
        CloudFilesInterop.ThrowIfFailed(CloudFilesInterop.CfSetPinState(handle.DangerousGetHandle(), CloudFilesInterop.PinStatePinned, 0, IntPtr.Zero), "CfSetPinState.delete-check");
    }
    CloudFilePlaceholderNative.RequireSynchronized(pinnedDeletePath, "synthetic-external-rename", false);
    Require(!CloudFilePlaceholderNative.ReleaseCachedContent(pinnedDeletePath, "synthetic-external-rename"), "缓存释放不能取消固定离线");
    Require(!CloudFilePlaceholderNative.Remove(pinnedDeletePath, "synthetic-external-rename", false, removalGate), "缓存清理仍保留固定离线文件");
    Require(CloudFilePlaceholderNative.Remove(pinnedDeletePath, "synthetic-external-rename", false, removalGate, confirmedDeletion: true),
        "已确认删除可以清理原身份的已同步固定离线文件");
    var cachePath = Path.Combine(root, "cache-release.bin"); createdNames.Add("cache-release.bin");
    await File.WriteAllTextAsync(cachePath, "cache bytes");
    var cacheHash = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(Encoding.UTF8.GetBytes("cache bytes")));
    CloudFilePlaceholderNative.BindRenamedLocalFile(cachePath, "synthetic-cache");
    Require(!CloudFilePlaceholderNative.ReleaseCachedContent(cachePath, "synthetic-cache"), "未保存的新内容不能当缓存释放");
    Require(CloudFilePlaceholderNative.AcknowledgeSavedContent(cachePath, "synthetic-cache", 11, cacheHash), "合成缓存内容已经核查");
    var busyCacheProtected = false;
    using (var reader = new FileStream(cachePath, FileMode.Open, FileAccess.Read, FileShare.Read))
    {
        try { CloudFilePlaceholderNative.ReleaseCachedContent(cachePath, "synthetic-cache"); }
        catch (IOException) { busyCacheProtected = true; }
    }
    Require(busyCacheProtected, "正在读取的缓存不被释放");
    Require(CloudFilePlaceholderNative.ReleaseCachedContent(cachePath, "synthetic-cache") &&
        new FileInfo(cachePath).Length == 11 && (File.GetAttributes(cachePath) & FileAttributes.ReadOnly) != 0,
        "已保存缓存释放后保持原长度并恢复只读");
    var emptyDirectory = Path.Combine(root, "remote-removed-dir");
    CreateNamedPlaceholder(root, "remote-removed-dir", "synthetic-directory", directory: true);
    Require(CloudFilePlaceholderNative.Remove(emptyDirectory, "synthetic-directory", true, removalGate) && !Directory.Exists(emptyDirectory),
        "清理已同步的空目录而不递归删除");
    Directory.CreateDirectory(emptyDirectory);
    try
    {
        Require(CloudFilePlaceholderNative.AcknowledgeCreatedDirectory(emptyDirectory, "synthetic-directory"),
            "本地新建目录转换为本映射的已同步占位目录");
        Require(CloudFilePlaceholderNative.AcknowledgeCreatedDirectory(emptyDirectory, "synthetic-directory"),
            "目录确认重复调用保持同一身份");
    }
    finally
    {
        if ((File.GetAttributes(emptyDirectory) & FileAttributes.ReparsePoint) != 0)
            Require(CloudFilePlaceholderNative.Remove(emptyDirectory, "synthetic-directory", true, removalGate), "清理本次新建的合成目录");
        else Directory.Delete(emptyDirectory, recursive: false);
    }
    const string editName = "editable.bin";
    var replacementPath = Path.Combine(root, "replacement.bin"); createdNames.Add("replacement.bin");
    await File.WriteAllTextAsync(replacementPath, "synthetic renamed edit");
    CloudFilePlaceholderNative.BindRenamedLocalFile(replacementPath, "synthetic-replacement");
    Require(CloudFilePlaceholderNative.ReadIdentity(replacementPath) == "synthetic-replacement" &&
        CloudFilePlaceholderNative.IsModified(replacementPath, "synthetic-replacement") &&
        await File.ReadAllTextAsync(replacementPath) == "synthetic renamed edit", "普通改名文件绑定原身份且内容仍未同步");
    CloudFilePlaceholderNative.BindRenamedLocalFile(replacementPath, "synthetic-replacement");
    var wrongReplacementIdentityRejected = false;
    try { CloudFilePlaceholderNative.BindRenamedLocalFile(replacementPath, "different-replacement"); }
    catch (InvalidDataException) { wrongReplacementIdentityRejected = true; }
    Require(wrongReplacementIdentityRejected && CloudFilePlaceholderNative.IsModified(replacementPath, "synthetic-replacement"),
        "重复绑定不冒充已同步且错误身份不能夺取文件");
    const string editRemote = "/share/editable.bin";
    var editIdentity = DesktopDriveItemIdentity.Identifier(mapping.Id, editRemote)!;
    CreateNamedPlaceholder(root, editName, editIdentity, size: 0); createdNames.Add(editName);
    var editPath = Path.Combine(root, editName);
    var editStore = new DesktopCloudDriveSyncStore(syncDirectory);
    await editStore.SetWritebackEnabledAsync(mapping, true, true);
    await editStore.RegisterLocalNamesAsync(mapping, new Dictionary<string, string>(), [editRemote]);
    await editStore.BindEmptyFileBaselineAsync(mapping, editRemote, DateTimeOffset.UnixEpoch);
    CloudFilePlaceholderNative.SetWritable(editPath, editIdentity, true);
    Console.WriteLine("已允许编辑空占位。");
    await File.WriteAllTextAsync(editPath, "synthetic local edit");
    Console.WriteLine($"合成保存后类型：{File.GetAttributes(editPath)}");
    var edit = await new DesktopCloudDriveSyncStore(syncDirectory).CaptureMappedSaveAsync(mapping,
        Guid.NewGuid(), editRemote, editPath, root);
    Require(edit.EmptyBaseModifiedAt == DateTimeOffset.UnixEpoch, "捕获从重启后的记录读取编辑前空文件基线");
    await using (var content = await editStore.OpenContentAsync(mapping, edit.Id))
    using (var reader = new StreamReader(content))
        Require(await reader.ReadToEndAsync() == "synthetic local edit", "关闭后的真实占位修改可冻结为独立副本");
    await File.WriteAllTextAsync(editPath, "newer edit");
    Require(!CloudFilePlaceholderNative.AcknowledgeSavedContent(editPath, editIdentity, edit.ContentLength, edit.ContentHash)
        && CloudFilePlaceholderNative.IsModified(editPath, editIdentity), "较新本地修改不能被旧上传结果标成已同步");
    await File.WriteAllTextAsync(editPath, "synthetic local edit");
    Require(CloudFilePlaceholderNative.AcknowledgeSavedContent(editPath, editIdentity, edit.ContentLength, edit.ContentHash)
        && !CloudFilePlaceholderNative.IsModified(editPath, editIdentity), "核对相同内容后恢复占位身份和已同步状态");
    Require(await File.ReadAllTextAsync(editPath) == "synthetic local edit", "确认保存不会丢弃本地内容");
    using (var handle = Open(editPath))
        CloudFilesInterop.ThrowIfFailed(CloudFilesInterop.CfSetInSyncState(handle, 0, 0, IntPtr.Zero), "CfSetInSyncState.synthetic-edit");
    Require(CloudFilePlaceholderNative.IsModified(editPath, editIdentity)
        && CloudFilePlaceholderNative.AcknowledgeSavedContent(editPath, editIdentity, edit.ContentLength, edit.ContentHash)
        && !CloudFilePlaceholderNative.IsModified(editPath, editIdentity), "已有占位的同步状态同样按内容核对后恢复");
    var renamedPath = Path.Combine(root, "renamed.bin");
    File.Move(editPath, renamedPath); createdNames.Add("renamed.bin"); editPath = renamedPath;
    var upperPath = Path.Combine(root, "RENAMED.bin"); createdNames.Add("RENAMED.bin");
    void VerifyRenamedIdentity(string path)
    {
        using var handle = CloudFilesInterop.CreateFile(path, 0x80, CloudFilesInterop.FileShareReadWriteDelete, IntPtr.Zero,
            CloudFilesInterop.OpenExisting, CloudFilesInterop.FileFlagOpenReparsePoint, IntPtr.Zero);
        Require(!handle.IsInvalid, "大小写改名对象可读取");
        _ = CloudFilePlaceholderNative.Read(handle, editIdentity);
    }
    CloudFileRenamePaths.CompleteLocalMove(renamedPath, upperPath, false, true, VerifyRenamedIdentity);
    Require(CloudFileRenamePaths.HasExactLeafName(upperPath) && !CloudFileRenamePaths.HasExactLeafName(renamedPath), "占位文件大小写改名确实完成");
    CloudFileRenamePaths.CompleteLocalMove(upperPath, renamedPath, false, true, VerifyRenamedIdentity);
    using (var handle = Open(editPath))
        _ = CloudFilePlaceholderNative.Read(handle, editIdentity);
    await editStore.RelocatePathsAsync(mapping, new(Guid.NewGuid(), editRemote, "/share/renamed.bin", "renamed.bin"));
    var relocated = await editStore.ReadChangesAsync(mapping);
    Require(relocated.Single().Id == edit.Id && relocated.Single().RemotePath == "/share/renamed.bin",
        "真实本地改名保留原身份及待同步副本编号");
    using (var handle = Open(editPath))
        CloudFilesInterop.ThrowIfFailed(CloudFilesInterop.CfSetInSyncState(handle, 0, 0, IntPtr.Zero), "CfSetInSyncState.synthetic-kept");
    CloudFilePlaceholderNative.PreserveLocallyReadOnly(editPath, editIdentity);
    Require((File.GetAttributes(editPath) & FileAttributes.ReadOnly) != 0 && CloudFilePlaceholderNative.IsModified(editPath, editIdentity),
        "保留本地可以恢复只读但不能伪装已保存到 NAS");
    CloudFilesInterop.ThrowIfFailed(CloudFilesInterop.CfDisconnectSyncRoot(connection), "CfDisconnectSyncRoot.retained");
    connected = false;
    Require(CloudFilePlaceholderNative.ReadIdentity(replacementPath) == "synthetic-replacement" &&
        await File.ReadAllTextAsync(replacementPath) == "synthetic renamed edit", "断开后普通改名文件的身份与修改仍可恢复");
    Require(await File.ReadAllTextAsync(editPath) == "synthetic local edit", "断开后保留的完整本地内容仍可读取");
    Console.WriteLine("PASS：隔离 Cloud Files 原生刷新检查完成。");
    return 0;
}
catch (Exception error)
{
    Console.Error.WriteLine($"FAIL：{error.GetType().Name}，HRESULT=0x{error.HResult:X8}；不视为系统验收通过。");
    return 1;
}
finally
{
    if (connected) CloudFilesInterop.ThrowIfFailed(CloudFilesInterop.CfDisconnectSyncRoot(connection), "CfDisconnectSyncRoot");
    GC.KeepAlive(deleteCallback);
    GC.KeepAlive(renameCallback); GC.KeepAlive(renamedCallback);
    GC.KeepAlive(metadataCallback);
    if (registered) { CleanupGeneratedRoot(root); registered = false; }
    // 仅清理由本程序生成的固定文件与空根目录，不递归遍历任何用户目录。
    if (File.Exists(file)) { File.SetAttributes(file, FileAttributes.Normal); File.Delete(file); }
    foreach (var name in createdNames)
    {
        var generated = Path.Combine(root, name);
        if (File.Exists(generated)) { File.SetAttributes(generated, FileAttributes.Normal); File.Delete(generated); }
    }
    if (Directory.Exists(root)) Directory.Delete(root, recursive: false);
    var stateDirectory = Path.Combine(syncDirectory, mapping.Id.ToString("N"));
    foreach (var name in new[] { "state.json", "write.lock" })
    {
        var generated = Path.Combine(stateDirectory, name);
        if (File.Exists(generated)) File.Delete(generated);
    }
    if (Directory.Exists(stateDirectory)) Directory.Delete(stateDirectory, recursive: false);
    if (Directory.Exists(syncDirectory)) Directory.Delete(syncDirectory, recursive: false);
    if (File.Exists(root + "-test-marker")) File.Delete(root + "-test-marker");
    Console.WriteLine("已注销并清理本次生成的测试同步根。");
}
static Microsoft.Win32.SafeHandles.SafeFileHandle Open(string path)
{
    var handle = CloudFilesInterop.CreateFile(path, 0x00040080, CloudFilesInterop.FileShareReadWriteDelete,
        IntPtr.Zero, CloudFilesInterop.OpenExisting, CloudFilesInterop.FileFlagOpenReparsePoint, IntPtr.Zero);
    if (handle.IsInvalid) { handle.Dispose(); throw new IOException("无法打开合成占位文件"); }
    return handle;
}
static void Require(bool condition, string name)
{
    if (!condition) throw new InvalidOperationException(name);
    Console.WriteLine("PASS：" + name);
}

static void CreateNamedPlaceholder(string root, string name, string identity, bool directory = false, long size = 16)
{
    var fileName = Marshal.StringToHGlobalUni(name); var bytes = Encoding.UTF8.GetBytes(identity); var id = Marshal.AllocHGlobal(bytes.Length);
    try
    {
        Marshal.Copy(bytes, 0, id, bytes.Length);
        var values = new[] { new CloudFilesInterop.PlaceholderCreateInfo { RelativeFileName = fileName,
            FileIdentity = id, FileIdentityLength = (uint)bytes.Length, Flags = CloudFilesInterop.PlaceholderMarkInSync,
            FileSystemMetadata = new() { FileSize = directory ? 0 : size, BasicInfo = new() { FileAttributes = directory ? 0x11u : 1u } } } };
        CloudFilesInterop.ThrowIfFailed(CloudFilesInterop.CfCreatePlaceholders(root, values, 1, 0, out var processed), "CfCreatePlaceholders");
        Require(processed == 1 && values[0].Result >= 0, "新增稳定命名的占位文件");
    }
    finally { Marshal.FreeHGlobal(id); Marshal.FreeHGlobal(fileName); }
}

static void CleanupGeneratedRoot(string root)
{
    if (!Directory.Exists(root)) return;
    if (!File.Exists(root + "-test-marker") || File.ReadAllText(root + "-test-marker") != Path.GetFileName(root))
        throw new IOException("缺少合成根标记，停止清理。");
    var directories = Directory.GetDirectories(root);
    if (directories.Any(path => Path.GetFileName(path) is not ("recycle-folder" or "all-shares-fixture") || Directory.EnumerateDirectories(path).Any() ||
        Directory.EnumerateFiles(path).Any(file => Path.GetFileName(file) != (Path.GetFileName(path) == "recycle-folder" ? "nested.bin" : "edit.txt"))))
        throw new IOException("合成根包含未知子目录，停止清理。");
    var files = Directory.GetFiles(root).Concat(directories.SelectMany(Directory.GetFiles)).ToArray();
    if (files.Any(path => Path.GetFileName(path) is not ("synthetic.bin" or "remote-removed.bin" or "Report.txt" or "editable.bin" or "replacement.bin" or "renamed.bin" or "RENAMED.bin" or "external-source.bin" or "external-target.bin" or "cold.bin" or "cold-renamed.bin" or "recycle-file.bin" or "cache-release.bin") &&
        !(Path.GetFileName(path) == "nested.bin" && Path.GetDirectoryName(path) == Path.Combine(root, "recycle-folder")) &&
        !(Path.GetFileName(path) == "edit.txt" && Path.GetDirectoryName(path) == Path.Combine(root, "all-shares-fixture")) &&
        !Path.GetFileName(path).StartsWith("report.txt~", StringComparison.Ordinal))) throw new IOException("合成根包含未知文件，停止清理。");
    var registration = new CloudFilesInterop.SyncRegistration { StructSize = (uint)Marshal.SizeOf<CloudFilesInterop.SyncRegistration>(),
        ProviderName = "LanStash Synthetic Check", ProviderVersion = "1.0", ProviderId = Guid.NewGuid() };
    var policies = new CloudFilesInterop.SyncPolicies { StructSize = (uint)Marshal.SizeOf<CloudFilesInterop.SyncPolicies>(),
        Hydration = new() { Primary = 1 }, Population = new() { Primary = 0 } };
    CloudFilesInterop.ThrowIfFailed(CloudFilesInterop.CfRegisterSyncRoot(root, registration, policies,
        CloudFilesInterop.RegisterUpdate | CloudFilesInterop.RegisterMarkRootInSync), "CfRegisterSyncRoot.cleanup");
    CloudFilesInterop.Callback cleanupData = (in CloudFilesInterop.CallbackInfo info, IntPtr _) =>
    {
        var length = info.FileSize is >= 0 and <= 16384 ? info.FileSize : -1;
        var bytes = Marshal.AllocHGlobal((int)Math.Max(1, length));
        var parameters = Marshal.AllocHGlobal(Marshal.SizeOf<CloudFilesInterop.TransferDataParameters>());
        try
        {
            if (length > 0) Marshal.Copy(new byte[length], 0, bytes, (int)length);
            var value = new CloudFilesInterop.TransferDataParameters { ParamSize = (uint)Marshal.SizeOf<CloudFilesInterop.TransferDataParameters>(),
                Buffer = bytes, Offset = 0, Length = Math.Max(0, length), CompletionStatus = length < 0 ? CloudFilesInterop.StatusAccessDenied : 0 };
            Marshal.StructureToPtr(value, parameters, false);
            var operation = new CloudFilesInterop.OperationInfo { StructSize = (uint)Marshal.SizeOf<CloudFilesInterop.OperationInfo>(),
                Type = 0, ConnectionKey = info.ConnectionKey, TransferKey = info.TransferKey, RequestKey = info.RequestKey };
            _ = CloudFilesInterop.CfExecute(operation, parameters);
        }
        finally { Marshal.FreeHGlobal(parameters); Marshal.FreeHGlobal(bytes); }
    };
    CloudFilesInterop.ThrowIfFailed(CloudFilesInterop.CfConnectSyncRoot(root,
        [new() { Type = CloudFilesInterop.CallbackFetchData, Callback = cleanupData }, new() { Type = CloudFilesInterop.CallbackNone }],
        IntPtr.Zero, 0, out var cleanupConnection), "CfConnectSyncRoot.cleanup");
    foreach (var path in files)
    {
        if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) == 0) continue;
        using var handle = Open(path);
        CloudFilesInterop.ThrowIfFailed(CloudFilesInterop.CfSetPinState(handle.DangerousGetHandle(), 2, 0, IntPtr.Zero), "CfSetPinState.cleanup");
        CloudFilesInterop.ThrowIfFailed(CloudFilesInterop.CfSetInSyncState(handle, 1, 0, IntPtr.Zero), "CfSetInSyncState.cleanup");
        CloudFilesInterop.ThrowIfFailed(CloudFilesInterop.CfUpdatePlaceholder(handle, new() { FileSize = 0 },
            IntPtr.Zero, 0, IntPtr.Zero, 0, 7, IntPtr.Zero, IntPtr.Zero), "CfUpdatePlaceholder.cleanup");
        CloudFilesInterop.ThrowIfFailed(CloudFilesInterop.CfRevertPlaceholder(handle, 0, IntPtr.Zero), "CfRevertPlaceholder.cleanup");
    }
    CloudFilesInterop.ThrowIfFailed(CloudFilesInterop.CfDisconnectSyncRoot(cleanupConnection), "CfDisconnectSyncRoot.cleanup");
    GC.KeepAlive(cleanupData);
    CloudFilesInterop.ThrowIfFailed(CloudFilesInterop.CfUnregisterSyncRoot(root), "CfUnregisterSyncRoot.cleanup");
    foreach (var path in files) if (File.Exists(path)) { File.SetAttributes(path, FileAttributes.Normal); File.Delete(path); }
    foreach (var path in directories) { File.SetAttributes(path, FileAttributes.Normal); Directory.Delete(path, recursive: false); }
    Directory.Delete(root, recursive: false);
    var sync = root + "-sync";
    if (Directory.Exists(sync))
    {
        foreach (var directory in Directory.GetDirectories(sync))
        {
            if (!Guid.TryParseExact(Path.GetFileName(directory), "N", out _)) throw new IOException("未知测试记录目录。");
            foreach (var path in Directory.GetFiles(directory))
            {
                var name = Path.GetFileName(path);
                if (name is not ("state.json" or "write.lock" or "upload.lock") &&
                    !(name.EndsWith(".content", StringComparison.Ordinal) && Guid.TryParseExact(Path.GetFileNameWithoutExtension(name), "N", out _)))
                    throw new IOException("未知测试记录文件。");
                File.Delete(path);
            }
            Directory.Delete(directory, recursive: false);
        }
        Directory.Delete(sync, recursive: false);
    }
    File.Delete(root + "-test-marker");
    Console.WriteLine("已清理确认的合成同步根和记录；没有触碰生产映射。");
}
