using System.IO;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.NasAdmin;

public sealed class NasDetailsRepositoryContractTests
{
    private static readonly Guid ProfileId = Guid.NewGuid();
    private static readonly NasProfile Profile = new(
        ProfileId,
        "Synthetic NAS",
        "nas.invalid",
        5001,
        "tester");
    private static readonly DsmSession Session = new(
        ProfileId,
        "synthetic-sid",
        "synthetic-token",
        "synthetic-device");

    [Fact]
    public async Task LoadDetailsUsesFixedReadVersionsAndReturnsSafeProjection()
    {
        var api = new FakeApiClient();
        api.Responses["SYNO.Core.System"] = Json("""
            {"model":"DS-synthetic","firmware_ver":"7.2","up_time":"25:02:03","cpu_series":"Synthetic CPU","cpu_cores":"4","cpu_clock_speed":2400,"ram_size":4096,"sys_temp":42.5,"hostname":"private-host","serial":"system-secret"}
            """);
        api.Responses["SYNO.Storage.CGI.Storage"] = Json("""
            {"storagePools":[{"id":"private-pool-id","raidType":"raid1","summary_status":"normal","size":{"used":100,"total":200},"disks":["private-device"]}],"volumes":[{"uuid":"private-volume-id","vol_path":"/private/path","fs_type":"btrfs","is_encrypted":true,"status":"normal","size":{"used":50,"total":100}}],"disks":[{"device":"private-device","serial":"drive-secret","vendor":"private-vendor","model":"private-model","size_total":400,"smart_status":"normal","temp":37,"isSsd":true,"status":"normal"}]}
            """);
        api.Responses["SYNO.Core.Upgrade.Server"] = Json("""
            {"update":{"version":" 7.2.1 ","release_note":" Reliability improvements ","download_url":"https://private.invalid/update","serial":"update-secret"},"promotion":{"version":"9.9"},"task_id":"private-task"}
            """);
        api.ResponseSequences["SYNO.FileStation.List"] = new Queue<JsonObject>(
        [
            Json("""
                {"offset":0,"total":4,"shares":[{"name":"Projects","path":"/private/projects","isdir":true,"additional":{"mount_point_type":"normal","owner":"private-owner","perm":{"adv_right":{"read":true,"write":true,"delete":true},"private_acl":"secret"}}},{"name":"Archive","path":"/private/archive","isdir":true,"additional":{"mount_point_type":"normal","perm":{"adv_right":{"read":true,"write":false,"delete":false}}}},{"name":"Remote","path":"/private/remote","isdir":true,"additional":{"mount_point_type":"cifs","perm":{"adv_right":{"read":true,"write":true,"delete":true}}}},{"name":"#recycle","path":"/private/#recycle","isdir":true,"additional":{"mount_point_type":"normal","perm":{"adv_right":{"read":true,"write":true,"delete":true}}}}]}
                """),
            Json("""
                {"offset":0,"total":4,"shares":[{"name":"Projects","path":"/private/projects","isdir":true,"additional":{"mount_point_type":"normal","perm":{"adv_right":{"read":true}}}},{"name":"Archive","path":"/private/archive","isdir":true,"additional":{"mount_point_type":"normal","perm":{"adv_right":{"read":true}}}},{"name":"Remote","path":"/private/remote","isdir":true,"additional":{"mount_point_type":"cifs"}},{"name":"#recycle","path":"/private/#recycle","isdir":true,"additional":{"mount_point_type":"normal"}}]}
                """),
            Json("""
                {"offset":0,"total":4,"files":[{"name":"photo.jpg","path":"/private/projects/photo.jpg","isdir":false,"size":4096,"additional":{"time":{"mtime":1000}}},{"name":"photo.jpg","path":"/private/projects/copy/photo.jpg","isdir":false,"size":4096,"additional":{"time":{"mtime":900}}},{"name":"report.pdf","path":"/private/projects/report.pdf","isdir":false,"size":2048,"mtime":1100},{"name":"movie.mp4","path":"/private/projects/movie.mp4","isdir":false,"size":8192,"mtime":1200}]}
                """),
            Json("""
                {"offset":0,"total":1,"files":[{"name":"backup.zip","path":"/private/archive/backup.zip","isdir":false,"size":1024,"mtime":800}]}
                """),
        ]);
        api.Responses["SYNO.Core.System.Process"] = Json("""
            {"total":1,"processes":[{"pid":42,"name":"/private/bin/indexer","status":"running","group_id":"service-a","command_line":"--private","user":"private-user","working_directory":"/private/work","listen_port":5000,"source_address":"192.0.2.1"}]}
            """);
        api.Responses["SYNO.Core.System.ProcessGroup"] = Json("""
            {"groups":[{"id":"service-a","display_name":"Indexing","status":"running","process_count":1,"account":"private-user","path":"/private/service"}]}
            """);
        api.Responses["SYNO.Core.Package"] = Json("""
            {"packages":[{"id":"pkg-drive","name":"Drive","version":"3.0","status":"running","description":"hidden"}]}
            """);
        api.Responses["SYNO.Core.TaskScheduler"] = Json("""
            {"tasks":[{"id":"task-1","name":"Backup","enable":true,"next_trigger_time":"Tonight","script":"secret"}]}
            """);
        api.Responses["SYNO.LogCenter.History"] = Json("""
            {"logs":[{"id":"log-1","source":"System","level":"info","message":"sensitive log body","user":"admin","time":0}]}
            """);
        api.Responses["SYNO.Core.CurrentConnection"] = Json("""
            {"connections":[{"id":"conn-1","protocol":"DSM","type":"web","source":"192.0.2.1","device_id":"secret","is_current":true,"time":0}]}
            """);
        var repository = Repository(api);

        var snapshot = await repository.LoadDetailsAsync();

        Assert.Equal(ProfileId, snapshot.ProfileId);
        var system = Assert.Single(snapshot.SystemOverview.Items);
        Assert.Equal("DS-synthetic", system.Model);
        Assert.Equal(90_123, system.UptimeSeconds);
        Assert.Equal(4L * 1024 * 1024 * 1024, system.MemoryBytes);
        var storage = snapshot.StorageHealth.Items;
        Assert.Equal(3, storage.Count);
        Assert.Equal(new[] { "pool-1", "volume-1", "drive-1" }, storage.Select(item => item.Id));
        var update = Assert.Single(snapshot.SystemUpdate.Items);
        Assert.True(update.IsUpdateAvailable);
        Assert.Equal("7.2", update.CurrentVersion);
        Assert.Equal("7.2.1", update.LatestVersion);
        Assert.Equal("Reliability improvements", update.ReleaseNotes);
        Assert.Equal(new[] { "Archive", "Projects" }, snapshot.ShareAccess.Items.Select(item => item.Name));
        Assert.Equal(NasShareAccessLevel.ReadOnly, snapshot.ShareAccess.Items[0].AccessLevel);
        Assert.Equal(NasShareAccessLevel.ReadWrite, snapshot.ShareAccess.Items[1].AccessLevel);
        Assert.True(snapshot.ShareAccess.Items[1].CanDelete);
        var analysis = Assert.Single(snapshot.StorageAnalysis.Items);
        Assert.Equal(2, analysis.ScannedShareCount);
        Assert.Equal(5, analysis.ScannedFileCount);
        Assert.Contains(analysis.Categories, item =>
            item.Category == NasStorageAnalysisCategory.Images &&
            item.FileCount == 2);
        Assert.Equal("movie.mp4", Assert.Single(analysis.LargeFiles.Take(1)).Name);
        Assert.Contains(analysis.DuplicateCandidates, item =>
            item.Name == "photo.jpg" && item.FileCount == 2);
        var activity = Assert.Single(snapshot.SystemActivity.Items);
        var process = Assert.Single(activity.Processes);
        Assert.Equal(42, process.ProcessId);
        Assert.Equal("indexer", process.Name);
        Assert.Equal("Indexing", Assert.Single(activity.Groups).Name);
        Assert.DoesNotContain("private", activity.ToString(), StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("192.0.2.1", activity.ToString(), StringComparison.Ordinal);
        var safeProjection = snapshot.ToString();
        Assert.DoesNotContain("private-host", safeProjection, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("system-secret", safeProjection, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("private-device", safeProjection, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("private-path", safeProjection, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("drive-secret", safeProjection, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("private-vendor", safeProjection, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("private-model", safeProjection, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("private.invalid", safeProjection, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("private-task", safeProjection, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("update-secret", safeProjection, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("/private/", safeProjection, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("private-owner", safeProjection, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("private_acl", safeProjection, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("/private/projects", safeProjection, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("/private/archive", safeProjection, StringComparison.OrdinalIgnoreCase);
        Assert.Equal("Drive", Assert.Single(snapshot.Packages.Items).Name);
        Assert.Equal("Backup", Assert.Single(snapshot.ScheduledTasks.Items).Name);
        var log = Assert.Single(snapshot.Logs.Items);
        Assert.Equal("System", log.Source);
        Assert.DoesNotContain("sensitive", log.ToString(), StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("admin", log.ToString(), StringComparison.OrdinalIgnoreCase);
        var connection = Assert.Single(snapshot.Connections.Items);
        Assert.Equal("DSM", connection.Protocol);
        Assert.DoesNotContain("192.0.2.1", connection.ToString(), StringComparison.Ordinal);
        Assert.DoesNotContain("secret", connection.ToString(), StringComparison.OrdinalIgnoreCase);
        Assert.Equal(
            new[]
            {
                "SYNO.Core.System:3:info",
                "SYNO.Storage.CGI.Storage:1:load_info",
                "SYNO.Core.Upgrade.Server:3:check",
                "SYNO.FileStation.List:2:list_share",
                "SYNO.Core.System.Process:1:list",
                "SYNO.Core.System.ProcessGroup:1:list",
                "SYNO.Core.Package:2:list",
                "SYNO.Core.TaskScheduler:3:list",
                "SYNO.LogCenter.History:1:list",
                "SYNO.Core.CurrentConnection:1:list",
                "SYNO.FileStation.List:2:list_share",
                "SYNO.FileStation.List:2:list",
                "SYNO.FileStation.List:2:list",
            },
            api.Calls.Select(call => $"{call.ApiName}:{call.Version}:{call.Method}").ToArray());
        var updateCall = api.Calls.Single(call => call.ApiName == "SYNO.Core.Upgrade.Server");
        Assert.Equal(
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["user_reading"] = "true",
                ["need_auto_smallupdate"] = "true",
                ["need_promotion"] = "false",
            },
            updateCall.Parameters);
        var shareCall = api.Calls.First(call => call.ApiName == "SYNO.FileStation.List");
        Assert.Equal("[\"mount_point_type\",\"perm\"]", shareCall.Parameters["additional"]);
        Assert.Equal("name", shareCall.Parameters["sort_by"]);
        Assert.Equal("asc", shareCall.Parameters["sort_direction"]);
        var analysisFileCalls = api.Calls
            .Where(call => call.ApiName == "SYNO.FileStation.List" && call.Method == "list")
            .ToArray();
        Assert.Equal(new[] { "/private/projects", "/private/archive" },
            analysisFileCalls.Select(call => call.Parameters["folder_path"]));
        Assert.All(analysisFileCalls, call =>
        {
            Assert.Equal("50", call.Parameters["limit"]);
            Assert.Equal("size", call.Parameters["sort_by"]);
            Assert.Equal("desc", call.Parameters["sort_direction"]);
            Assert.Equal("file", call.Parameters["filetype"]);
        });
        foreach (var call in api.Calls.Where(call => call.ApiName.StartsWith("SYNO.Core.System.Process", StringComparison.Ordinal)))
        {
            Assert.Equal("0", call.Parameters["start"]);
            Assert.Equal("500", call.Parameters["limit"]);
        }
    }

    [Fact]
    public async Task StorageAnalysisCanReloadIndependentlyWithFileStationListOnly()
    {
        var api = new FakeApiClient();
        api.ResponseSequences["SYNO.FileStation.List"] = new Queue<JsonObject>(
        [
            Json("""
                {"offset":0,"total":1,"shares":[{"name":"Projects","path":"/private/projects","isdir":true,"additional":{"mount_point_type":"normal"}}]}
                """),
            Json("""
                {"offset":0,"total":1,"files":[{"name":"photo.jpg","path":"/private/projects/photo.jpg","isdir":false,"size":4096,"mtime":1200}]}
                """),
        ]);
        var repository = Repository(api);

        var section = await repository.LoadStorageAnalysisAsync();

        var analysis = Assert.Single(section.Items);
        Assert.Equal(NasDetailsSectionStatus.Available, section.Status);
        Assert.Equal(1, analysis.ScannedShareCount);
        Assert.Equal(1, analysis.ScannedFileCount);
        Assert.Equal(4096, analysis.SampledBytes);
        Assert.Equal(
            new[]
            {
                "SYNO.FileStation.List:2:list_share",
                "SYNO.FileStation.List:2:list",
            },
            api.Calls.Select(call => $"{call.ApiName}:{call.Version}:{call.Method}").ToArray());
        Assert.DoesNotContain(api.Calls, call => call.ApiName.StartsWith("SYNO.Core.", StringComparison.Ordinal));
    }

    [Fact]
    public async Task DeepStorageAnalysisWalksBoundedFoldersAndConfirmsContentDuplicates()
    {
        var api = new FakeApiClient();
        api.ResponseSequences["SYNO.FileStation.List"] = new Queue<JsonObject>(
        [
            Json("""
                {"offset":0,"total":1,"shares":[{"name":"Projects","path":"/private/projects","isdir":true,"additional":{"mount_point_type":"normal"}}]}
                """),
            Json("""
                {"offset":0,"total":3,"files":[{"name":"Docs","path":"/private/projects/docs","isdir":true},{"name":"plan.pdf","path":"/private/projects/plan.pdf","isdir":false,"size":4096,"additional":{"owner":{"user":"owner-a"},"time":{"mtime":1300,"atime":900}}},{"name":"photo.jpg","path":"/private/projects/photo.jpg","isdir":false,"size":2048,"additional":{"owner":"owner-b","time":{"mtime":1200,"atime":800}}}]}
                """),
            Json("""
                {"offset":0,"total":2,"files":[{"name":"plan.pdf","path":"/private/projects/docs/plan.pdf","isdir":false,"size":4096,"additional":{"owner":{"user":"owner-a"},"time":{"mtime":1100,"atime":700}}},{"name":"notes.txt","path":"/private/projects/docs/notes.txt","isdir":false,"size":1024,"additional":{"owner":"owner-b","time":{"mtime":1000}}}]}
                """),
        ]);
        api.ResponseSequences["SYNO.FileStation.MD5"] = new Queue<JsonObject>(
        [
            Json("""{"taskid":"md5-a"}"""),
            Json("""{"finished":true,"md5":"ABCDEF0123456789ABCDEF0123456789"}"""),
            Json("""{"taskid":"md5-b"}"""),
            Json("""{"finished":true,"md5":"abcdef0123456789abcdef0123456789"}"""),
        ]);
        api.ResponseSequences["SYNO.FileStation.DirSize"] = new Queue<JsonObject>(
        [
            Json("""{"taskid":"dirsize-projects"}"""),
            Json("""{"finished":true,"total_size":11264,"num_file":4,"num_dir":1}"""),
            Json("""{"taskid":"dirsize-docs"}"""),
            Json("""{"finished":true,"total_size":5120,"num_file":2,"num_dir":0}"""),
        ]);
        var repository = Repository(
            api,
            includeFileMd5: true,
            includeDirectorySize: true,
            fastPolling: true);

        var section = await repository.LoadDeepStorageAnalysisAsync();

        var analysis = Assert.Single(section.Items);
        Assert.Equal(NasDetailsSectionStatus.Available, section.Status);
        Assert.True(analysis.IsDeepAnalysis);
        Assert.Equal(1, analysis.ScannedShareCount);
        Assert.Equal(2, analysis.ScannedFolderCount);
        Assert.Equal(4, analysis.ScannedFileCount);
        Assert.Equal(11_264, analysis.SampledBytes);
        Assert.False(analysis.IsPartial);
        Assert.Equal(4, analysis.OwnerSummary?.KnownOwnerFileCount);
        Assert.Equal(2, analysis.OwnerSummary?.DistinctOwnerCount);
        Assert.Equal(3, analysis.AccessTimeSummary?.KnownAccessTimeFileCount);
        Assert.Equal(DateTimeOffset.FromUnixTimeSeconds(700), analysis.AccessTimeSummary?.OldestAccessedAt);
        Assert.Contains(analysis.Directories ?? [], item =>
            item.Name == "projects" && item.FileCount == 4 && item.SizeBytes == 11_264);
        Assert.Contains(analysis.Directories ?? [], item =>
            item.Name == "docs" && item.FileCount == 2 && item.SizeBytes == 5_120);
        var duplicate = Assert.Single(analysis.DuplicateCandidates);
        Assert.True(duplicate.IsContentConfirmed);
        Assert.Equal("plan.pdf", duplicate.Name);
        Assert.Equal(2, duplicate.FileCount);
        Assert.DoesNotContain("/private/", analysis.ToString(), StringComparison.OrdinalIgnoreCase);
        Assert.Equal(
            new[]
            {
                "SYNO.FileStation.List:2:list_share",
                "SYNO.FileStation.List:2:list",
                "SYNO.FileStation.List:2:list",
                "SYNO.FileStation.MD5:2:start",
                "SYNO.FileStation.MD5:2:status",
                "SYNO.FileStation.MD5:2:start",
                "SYNO.FileStation.MD5:2:status",
                "SYNO.FileStation.DirSize:2:start",
                "SYNO.FileStation.DirSize:2:status",
                "SYNO.FileStation.DirSize:2:start",
                "SYNO.FileStation.DirSize:2:status",
            },
            api.Calls.Select(call => $"{call.ApiName}:{call.Version}:{call.Method}").ToArray());
        var listCalls = api.Calls
            .Where(call => call.ApiName == "SYNO.FileStation.List" && call.Method == "list")
            .ToArray();
        Assert.All(listCalls, call =>
        {
            Assert.Equal("name", call.Parameters["sort_by"]);
            Assert.Equal("[\"size\",\"owner\",\"time\"]", call.Parameters["additional"]);
            Assert.False(call.Parameters.ContainsKey("filetype"));
        });
    }

    [Fact]
    public async Task FailedSectionDoesNotBlockOtherSections()
    {
        var api = new FakeApiClient();
        api.Responses["SYNO.Core.Package"] = Json("""{"packages":[{"id":"pkg","name":"Drive","status":"running"}]}""");
        api.Errors["SYNO.Core.TaskScheduler"] = new DsmException("failed", "retry");
        api.Errors["SYNO.Storage.CGI.Storage"] = new DsmException("failed", "retry");
        api.Errors["SYNO.FileStation.List"] = new DsmException("failed", "retry");
        api.Responses["SYNO.LogCenter.History"] = Json("""{"logs":[]}""");
        api.Responses["SYNO.Core.CurrentConnection"] = Json("""{"connections":[]}""");
        var repository = Repository(api);

        var snapshot = await repository.LoadDetailsAsync();

        Assert.Equal(NasDetailsSectionStatus.Available, snapshot.SystemOverview.Status);
        Assert.Equal(NasDetailsSectionStatus.Failed, snapshot.StorageHealth.Status);
        Assert.Equal(NasDetailsSectionStatus.Available, snapshot.SystemUpdate.Status);
        Assert.Equal(NasDetailsSectionStatus.Failed, snapshot.ShareAccess.Status);
        Assert.Equal(NasDetailsSectionStatus.Available, snapshot.SystemActivity.Status);
        Assert.Equal(NasDetailsSectionStatus.Available, snapshot.Packages.Status);
        Assert.Equal(NasDetailsSectionStatus.Failed, snapshot.ScheduledTasks.Status);
        Assert.Equal(NasDetailsSectionStatus.Available, snapshot.Logs.Status);
        Assert.Equal(NasDetailsSectionStatus.Available, snapshot.Connections.Status);
    }

    [Fact]
    public async Task SystemActivityCapabilityMissingMakesNoGuessedRequest()
    {
        var api = new FakeApiClient();

        var snapshot = await Repository(api, includeSystemActivity: false).LoadDetailsAsync();

        Assert.Equal(NasDetailsSectionStatus.Unavailable, snapshot.SystemActivity.Status);
        Assert.DoesNotContain(api.Calls, call =>
            call.ApiName.StartsWith("SYNO.Core.System.Process", StringComparison.Ordinal));
    }

    [Fact]
    public async Task SystemActivityGroupFailureKeepsSafeProcessSnapshot()
    {
        var api = new FakeApiClient();
        api.Responses["SYNO.Core.System.Process"] = Json("""
            {"processes":[{"pid":7,"name":"worker","group":"service-a"}]}
            """);
        api.Errors["SYNO.Core.System.ProcessGroup"] = new DsmException("failed", "retry");

        var snapshot = await Repository(api).LoadDetailsAsync();

        var activity = Assert.Single(snapshot.SystemActivity.Items);
        Assert.Equal("worker", Assert.Single(activity.Processes).Name);
        Assert.Empty(activity.Groups);
        Assert.True(activity.AreGroupsUnavailable);
    }

    [Fact]
    public async Task SystemActivityFullGroupPageKeepsRowsAndReportsIncompleteDetails()
    {
        var api = new FakeApiClient();
        api.Responses["SYNO.Core.System.Process"] = Json("""
            {"processes":[{"pid":7,"name":"worker","group":"service-0"}]}
            """);
        var groups = string.Join(",", Enumerable.Range(0, 500)
            .Select(index => $$"""{"id":"service-{{index}}","name":"Service {{index}}"}"""));
        api.Responses["SYNO.Core.System.ProcessGroup"] = Json($"{{\"groups\":[{groups}]}}");

        var snapshot = await Repository(api).LoadDetailsAsync();

        var activity = Assert.Single(snapshot.SystemActivity.Items);
        Assert.Equal("Service 0", Assert.Single(activity.Groups).Name);
        Assert.True(activity.AreGroupsUnavailable);
    }

    [Fact]
    public async Task SystemActivityMalformedProcessPayloadFailsOnlyItsSection()
    {
        var api = new FakeApiClient();
        api.Responses["SYNO.Core.System.Process"] = Json("""{"processes":{}}""");

        var snapshot = await Repository(api).LoadDetailsAsync();

        Assert.Equal(NasDetailsSectionStatus.Failed, snapshot.SystemActivity.Status);
        Assert.Equal(NasDetailsSectionStatus.Available, snapshot.Packages.Status);
        Assert.Equal(NasDetailsSectionStatus.Available, snapshot.Connections.Status);
    }

    [Fact]
    public void SystemActivitySourceKeepsUnknownAndWriteMethodsClosed()
    {
        var source = File.ReadAllText(FindRepositoryFile());

        Assert.Contains("SYNO.Core.System.Process", source, StringComparison.Ordinal);
        Assert.Contains("SystemActivityApiVersion = 1", source, StringComparison.Ordinal);
        Assert.DoesNotContain("service_info", source, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("kill_process", source, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("terminate", source, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("command_line", source, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("working_directory", source, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("environment_variables", source, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task SystemActivityLimitsVisibleProcessesAndRejectsContradictoryTotal()
    {
        var api = new FakeApiClient();
        var processes = string.Join(",", Enumerable.Range(1, 51)
            .Select(index => $$"""{"pid":{{index}},"name":"Process {{index:D2}}"}"""));
        api.Responses["SYNO.Core.System.Process"] = Json($"{{\"total\":51,\"processes\":[{processes}]}}");

        var snapshot = await Repository(api).LoadDetailsAsync();

        Assert.True(snapshot.SystemActivity.IsTruncated);
        Assert.Equal(50, Assert.Single(snapshot.SystemActivity.Items).Processes.Count);

        api.Responses["SYNO.Core.System.Process"] = Json("""
            {"total":0,"processes":[{"pid":1,"name":"worker"}]}
            """);
        var failed = await Repository(api).LoadDetailsAsync();
        Assert.Equal(NasDetailsSectionStatus.Failed, failed.SystemActivity.Status);
    }

    [Fact]
    public async Task ShareAccessUsesBoundedPaginationAndLaterDuplicateWins()
    {
        var api = new FakeApiClient();
        api.ResponseSequences["SYNO.FileStation.List"] = new Queue<JsonObject>(
        [
            Json("""{"offset":0,"total":3,"shares":[{"name":"Data","path":"/private/data","isdir":true,"additional":{"mount_point_type":"normal","perm":{"adv_right":{"read":true,"write":false,"delete":false}}}},{"name":"Remote","path":"/private/remote","isdir":true,"additional":{"mount_point_type":"nfs"}}]}"""),
            Json("""{"offset":2,"total":3,"shares":[{"name":"Data","path":"/private/data","isdir":true,"additional":{"mount_point_type":"normal","perm":{"adv_right":{"read":true,"write":true,"delete":false}}}}]}"""),
        ]);

        var snapshot = await Repository(api).LoadDetailsAsync();

        var share = Assert.Single(snapshot.ShareAccess.Items);
        Assert.Equal("Data", share.Name);
        Assert.Equal(NasShareAccessLevel.ReadWrite, share.AccessLevel);
        Assert.False(share.CanDelete);
        Assert.Equal(
            new[] { "0", "2" },
            api.Calls.Where(call => call.ApiName == "SYNO.FileStation.List")
                .Where(call => call.Method == "list_share")
                .Select(call => call.Parameters["offset"])
                .Take(2));
        Assert.DoesNotContain("/private/", snapshot.ShareAccess.ToString(), StringComparison.Ordinal);
    }

    [Fact]
    public async Task MissingPermissionBitsRemainUnknownInsteadOfDenied()
    {
        var api = new FakeApiClient();
        api.Responses["SYNO.FileStation.List"] = Json("""
            {"offset":0,"total":1,"shares":[{"name":"Visible","path":"/private/visible","isdir":true,"additional":{"mount_point_type":"shared_folder"}}]}
            """);

        var snapshot = await Repository(api).LoadDetailsAsync();

        var share = Assert.Single(snapshot.ShareAccess.Items);
        Assert.Equal(NasShareAccessLevel.Unknown, share.AccessLevel);
        Assert.False(share.CanDelete);
    }

    [Fact]
    public async Task ShareAccessIsLimitedToFirstFiftySafeItems()
    {
        var api = new FakeApiClient();
        var shares = string.Join(",", Enumerable.Range(0, 51)
            .Select(index => $$"""{"name":"Share {{index:D2}}","path":"/private/share-{{index}}","isdir":true}"""));
        api.Responses["SYNO.FileStation.List"] = Json($"{{\"offset\":0,\"total\":51,\"shares\":[{shares}]}}");

        var snapshot = await Repository(api).LoadDetailsAsync();

        Assert.True(snapshot.ShareAccess.IsTruncated);
        Assert.Equal(50, snapshot.ShareAccess.Items.Count);
        Assert.DoesNotContain("/private/", snapshot.ShareAccess.ToString(), StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("null")]
    [InlineData("{\"version\":\"7.2\",\"release_notes\":\"Same version\"}")]
    public async Task MissingOrSameCandidateDoesNotInventAnAvailableUpdate(string updateJson)
    {
        var api = new FakeApiClient();
        api.Responses["SYNO.Core.System"] = Json("""{"firmware_ver":"7.2"}""");
        api.Responses["SYNO.Core.Upgrade.Server"] = Json($"{{\"update\":{updateJson},\"promotion\":{{\"version\":\"9.9\"}}}}");

        var snapshot = await Repository(api).LoadDetailsAsync();

        var update = Assert.Single(snapshot.SystemUpdate.Items);
        Assert.False(update.IsUpdateAvailable);
        Assert.Equal("7.2", update.CurrentVersion);
    }

    [Fact]
    public async Task ExplicitCandidateRemainsVisibleWhenSystemOverviewFails()
    {
        var api = new FakeApiClient();
        api.Errors["SYNO.Core.System"] = new DsmException("failed", "retry");
        api.Responses["SYNO.Core.Upgrade.Server"] = Json("""
            {"update":{"version":"7.2.2","description":" New release "}}
            """);

        var snapshot = await Repository(api).LoadDetailsAsync();

        Assert.Equal(NasDetailsSectionStatus.Failed, snapshot.SystemOverview.Status);
        var update = Assert.Single(snapshot.SystemUpdate.Items);
        Assert.True(update.IsUpdateAvailable);
        Assert.Null(update.CurrentVersion);
        Assert.Equal("7.2.2", update.LatestVersion);
        Assert.Equal("New release", update.ReleaseNotes);
    }

    [Fact]
    public async Task UpdateCheckFailureDoesNotBlockOtherSectionsOrReportCurrent()
    {
        var api = new FakeApiClient();
        api.Errors["SYNO.Core.Upgrade.Server"] = new DsmException("failed", "retry");

        var snapshot = await Repository(api).LoadDetailsAsync();

        Assert.Equal(NasDetailsSectionStatus.Failed, snapshot.SystemUpdate.Status);
        Assert.Empty(snapshot.SystemUpdate.Items);
        Assert.Equal(NasDetailsSectionStatus.Available, snapshot.SystemOverview.Status);
        Assert.Equal(NasDetailsSectionStatus.Available, snapshot.Packages.Status);
    }

    [Fact]
    public async Task SectionsAreLimitedToFirstFiftyItems()
    {
        var api = new FakeApiClient();
        var packageItems = string.Join(",", Enumerable.Range(0, 51)
            .Select(index => $$"""{"id":"pkg-{{index}}","name":"Package {{index}}","status":"running"}"""));
        api.Responses["SYNO.Core.Package"] = Json($"{{\"packages\":[{packageItems}]}}");
        api.Responses["SYNO.Core.TaskScheduler"] = Json("""{"tasks":[]}""");
        api.Responses["SYNO.LogCenter.History"] = Json("""{"logs":[]}""");
        api.Responses["SYNO.Core.CurrentConnection"] = Json("""{"connections":[]}""");
        var repository = Repository(api);

        var snapshot = await repository.LoadDetailsAsync();

        Assert.True(snapshot.Packages.IsTruncated);
        Assert.Equal(50, snapshot.Packages.Items.Count);
        Assert.Equal("pkg-49", snapshot.Packages.Items[^1].Id);
    }

    [Fact]
    public async Task StorageSectionUsesOneCombinedFiftyItemLimit()
    {
        var api = new FakeApiClient();
        var disks = string.Join(",", Enumerable.Range(0, 51)
            .Select(index => $$"""{"device":"private-{{index}}","status":"normal","size_total":100}"""));
        api.Responses["SYNO.Storage.CGI.Storage"] = Json($"{{\"storagePools\":[],\"volumes\":[],\"disks\":[{disks}]}}");
        var repository = Repository(api);

        var snapshot = await repository.LoadDetailsAsync();

        Assert.True(snapshot.StorageHealth.IsTruncated);
        Assert.Equal(50, snapshot.StorageHealth.Items.Count);
        Assert.Equal("drive-50", snapshot.StorageHealth.Items[^1].Id);
        Assert.DoesNotContain("private-", snapshot.StorageHealth.ToString(), StringComparison.Ordinal);
    }

    private static DsmRepository Repository(
        FakeApiClient api,
        bool includeSystemActivity = true,
        bool includeSystemActivityGroups = true,
        bool includeFileMd5 = false,
        bool includeDirectorySize = false,
        bool fastPolling = false)
    {
        api.Responses.TryAdd("SYNO.Core.System", Json("""{"model":"DS-synthetic"}"""));
        api.Responses.TryAdd("SYNO.Storage.CGI.Storage", Json("""{"storagePools":[],"volumes":[],"disks":[]}"""));
        api.Responses.TryAdd("SYNO.Core.Upgrade.Server", Json("""{"update":null}"""));
        api.Responses.TryAdd("SYNO.FileStation.List", Json("""{"offset":0,"total":0,"shares":[]}"""));
        api.Responses.TryAdd("SYNO.Core.System.Process", Json("""{"total":0,"processes":[]}"""));
        api.Responses.TryAdd("SYNO.Core.System.ProcessGroup", Json("""{"groups":[]}"""));
        api.Responses.TryAdd("SYNO.Core.Package", Json("""{"packages":[]}"""));
        api.Responses.TryAdd("SYNO.Core.TaskScheduler", Json("""{"tasks":[]}"""));
        api.Responses.TryAdd("SYNO.LogCenter.History", Json("""{"logs":[]}"""));
        api.Responses.TryAdd("SYNO.Core.CurrentConnection", Json("""{"connections":[]}"""));
        var capabilities = new Dictionary<string, ApiCapability>(StringComparer.Ordinal)
        {
            ["SYNO.Core.System"] = Capability("SYNO.Core.System", max: 3),
            ["SYNO.Storage.CGI.Storage"] = Capability("SYNO.Storage.CGI.Storage", max: 1),
            ["SYNO.Core.Upgrade.Server"] = Capability("SYNO.Core.Upgrade.Server", max: 3),
            ["SYNO.FileStation.List"] = Capability("SYNO.FileStation.List"),
            ["SYNO.Core.Package"] = Capability("SYNO.Core.Package"),
            ["SYNO.Core.TaskScheduler"] = Capability("SYNO.Core.TaskScheduler", max: 4),
            ["SYNO.LogCenter.History"] = Capability("SYNO.LogCenter.History"),
            ["SYNO.Core.CurrentConnection"] = Capability("SYNO.Core.CurrentConnection"),
        };
        if (includeSystemActivity)
        {
            capabilities["SYNO.Core.System.Process"] = Capability("SYNO.Core.System.Process", max: 1);
        }
        if (includeSystemActivityGroups)
        {
            capabilities["SYNO.Core.System.ProcessGroup"] = Capability("SYNO.Core.System.ProcessGroup", max: 1);
        }
        if (includeFileMd5)
        {
            capabilities["SYNO.FileStation.MD5"] = Capability("SYNO.FileStation.MD5");
        }
        if (includeDirectorySize)
        {
            capabilities["SYNO.FileStation.DirSize"] = Capability("SYNO.FileStation.DirSize");
        }
        return fastPolling
            ? new DsmRepository(Profile, Session, api, capabilities)
            {
                FileMD5InitialPollDelay = TimeSpan.Zero,
                FileMD5MaximumPollDelay = TimeSpan.Zero,
                DirectorySizeInitialPollDelay = TimeSpan.Zero,
                DirectorySizeMaximumPollDelay = TimeSpan.Zero,
            }
            : new DsmRepository(Profile, Session, api, capabilities);
    }

    private static ApiCapability Capability(string name, int max = 2) =>
        new(name, "entry.cgi", 1, max, "FORM");

    private static JsonObject Json(string source) =>
        JsonNode.Parse(source) as JsonObject ?? throw new InvalidDataException();

    private static string FindRepositoryFile()
    {
        var directory = new DirectoryInfo(Directory.GetCurrentDirectory());
        while (directory is not null)
        {
            var candidate = Path.Combine(
                directory.FullName,
                "windows/src/LanStash.Infrastructure/Features/NasAdmin/DsmRepository.NasDetails.cs");
            if (File.Exists(candidate))
            {
                return candidate;
            }
            directory = directory.Parent;
        }
        throw new DirectoryNotFoundException("DsmRepository.NasDetails.cs");
    }

    private sealed class FakeApiClient : IDsmApiClient
    {
        public Dictionary<string, JsonObject> Responses { get; } = new(StringComparer.Ordinal);
        public Dictionary<string, Exception> Errors { get; } = new(StringComparer.Ordinal);
        public Dictionary<string, Queue<JsonObject>> ResponseSequences { get; } = new(StringComparer.Ordinal);
        public List<ReadCall> Calls { get; } = [];

        public Uri GetBaseUri(NasProfile profile) => new("https://nas.invalid");

        public Task<IReadOnlyDictionary<string, ApiCapability>> DiscoverAsync(
            NasProfile profile,
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();

        public Task<DsmSession> LoginAsync(
            NasProfile profile,
            string password,
            string? otp,
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();

        public Task LogoutAsync(
            NasProfile profile,
            DsmSession session,
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();

        public Task<JsonObject> CallAsync(
            NasProfile profile,
            DsmSession session,
            ApiCapability capability,
            string method,
            IReadOnlyDictionary<string, string>? parameters = null,
            CancellationToken cancellationToken = default)
        {
            Calls.Add(new ReadCall(
                capability.Name,
                capability.MinVersion,
                method,
                parameters ?? new Dictionary<string, string>(StringComparer.Ordinal)));
            if (Errors.TryGetValue(capability.Name, out var error))
            {
                return Task.FromException<JsonObject>(error);
            }
            if (ResponseSequences.TryGetValue(capability.Name, out var responses) &&
                responses.Count > 0)
            {
                return Task.FromResult(responses.Dequeue());
            }
            return Task.FromResult(Responses[capability.Name]);
        }

        public Task<JsonObject> CallReadJsonObjectAsync(
            NasProfile profile,
            DsmSession session,
            ApiCapability capability,
            int requiredVersion,
            string method,
            IReadOnlyDictionary<string, string>? parameters = null,
            CancellationToken cancellationToken = default)
        {
            Calls.Add(new ReadCall(
                capability.Name,
                requiredVersion,
                method,
                parameters ?? new Dictionary<string, string>(StringComparer.Ordinal)));
            if (Errors.TryGetValue(capability.Name, out var error))
            {
                return Task.FromException<JsonObject>(error);
            }
            if (ResponseSequences.TryGetValue(capability.Name, out var responses) &&
                responses.Count > 0)
            {
                return Task.FromResult(responses.Dequeue());
            }
            return Task.FromResult(Responses[capability.Name]);
        }

        public Task<byte[]> ReadFileRangeAsync(
            NasProfile profile,
            DsmSession session,
            ApiCapability capability,
            string remotePath,
            long offset,
            long length,
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();
    }

    private sealed record ReadCall(
        string ApiName,
        int Version,
        string Method,
        IReadOnlyDictionary<string, string> Parameters);
}
