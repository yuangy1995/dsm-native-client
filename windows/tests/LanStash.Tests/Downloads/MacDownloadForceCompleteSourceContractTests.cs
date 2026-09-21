using System.Text.RegularExpressions;

namespace LanStash.Tests.Downloads;

/// <summary>Windows 上可执行的源码/资源回归，不替代 macOS Swift 或界面测试。</summary>
public sealed class MacDownloadForceCompleteSourceContractTests
{
    [Fact]
    public void AppleFileCreationChoosesDestinationVersionAndPreservesPasswordWhitespace()
    {
        var source = Read("apple/Packages/DsmNetwork/Sources/DsmServiceManagementRepository.swift");
        var start = source.IndexOf("private func callOfficialDownloadTaskFileCreate(", StringComparison.Ordinal);
        var end = source.IndexOf("\n    private func ", start + 10, StringComparison.Ordinal);
        var method = source[start..end];
        Assert.Contains("Self.nonEmpty(destination) == nil ? 1 : 2", method);
        Assert.Contains("capability.maxVersion >= requiredVersion", method);
        Assert.Contains("URLQueryItem(name: \"version\", value: String(requiredVersion))", method);
        Assert.Contains("if let unzipPassword, !unzipPassword.isEmpty", method);
        Assert.DoesNotContain("Self.nonEmpty(unzipPassword)", method);
        Assert.Contains("version: request.destination == nil ? 1 : 2", source);
        Assert.Contains("version: parameters[\"destination\"] == nil ? 1 : 2", source);
    }

    [Fact]
    public void MacEntryNamesTheForceCompleteActionAndKeepsLegacyProtocolLabelOnlyAtTheBoundary()
    {
        var view = Read("apple/Apps/DsmMac/Sources/ServiceManagementView.swift");
        var model = Read("apple/Apps/DsmMac/Sources/ServiceManagementModel.swift");
        Assert.DoesNotContain("taskAndData", view);
        Assert.Contains("case finishIncomplete", view);
        Assert.Contains("deleteDownloads(forceComplete: forceComplete)", view);
        Assert.Contains("func deleteDownloads(forceComplete: Bool)", model);
        Assert.Contains("removeData: forceComplete", model);
        Assert.Contains("download-task.finish-incomplete", model);
        Assert.Contains("force_complete", Read("apple/Packages/DsmNetwork/Sources/DsmServiceManagementRepository.swift"));
    }

    [Theory]
    [InlineData("en.lproj")]
    [InlineData("zh-Hans.lproj")]
    public void MacAndSharedResourcesAgreeAndDoNotAdvertiseDataDeletion(string locale)
    {
        var app = Read($"apple/Apps/DsmMac/Resources/{locale}/Localizable.strings");
        var shared = Read($"apple/Packages/DsmLocalization/Sources/Resources/{locale}/Localizable.strings");
        foreach (var key in new[] { "ui.810ad53a1c16de5d", "ui.631851c80f615dc3", "ui.7ee4c98525fb52f7", "ui.3719b045e8772446" }
                     .Concat(new[] { "confirm-title", "completed", "unverified", "partial", "cancelled", "permission-denied", "unsupported", "failed" }.Select(suffix => "download-task.finish-incomplete." + suffix)))
            Assert.Equal(Value(shared, key), Value(app, key));
        var title = Value(app, "ui.810ad53a1c16de5d");
        Assert.DoesNotContain("Remove tasks and downloaded data", title);
        Assert.DoesNotContain("移除任务和已下载数据", title);
        Assert.Contains(locale == "en.lproj" ? "Check the download destination" : "核对未完成文件", Value(app, "download-task.finish-incomplete.completed"));
    }

    private static string Value(string source, string key)
    {
        var matches = Regex.Matches(source, "^\"" + Regex.Escape(key) + "\"\\s*=\\s*\"(.*)\";\\s*$", RegexOptions.Multiline);
        return Assert.Single(matches.Cast<Match>()).Groups[1].Value;
    }
    private static string Read(string relative)
    {
        for (var directory = new DirectoryInfo(Directory.GetCurrentDirectory()); directory is not null; directory = directory.Parent)
        {
            var path = Path.Combine(directory.FullName, relative);
            if (File.Exists(path)) return File.ReadAllText(path).Replace("\r\n", "\n");
        }
        throw new FileNotFoundException(relative);
    }
}
