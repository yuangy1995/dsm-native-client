using System.Text;
using System.Security.Cryptography;
using LanStash.App.Features.Files.Preview;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Files;

public sealed class FileTextEditContractTests
{
    private static readonly NasProfile Profile = new(
        Guid.Parse("22222222-2222-2222-2222-222222222222"),
        "text-edit-test",
        "nas.invalid",
        5001,
        "editor");

    private static readonly DsmSession Session = new(
        Profile.Id,
        "text-edit-sid",
        "text-edit-token",
        null);

    // 下载不超过 5 MiB 的文本

    [Fact]
    public async Task DownloadTextContentReturnsFullFileWithin5MibLimit()
    {
        var content = new string('A', 1000);
        var bytes = new byte[] { 0xEF, 0xBB, 0xBF }
            .Concat(Encoding.UTF8.GetBytes(content))
            .ToArray();

        var api = new TextEditApiClient(rangeResponse: bytes, totalLength: bytes.Length);
        var repo = CreateRepository(api);

        var result = await ((IFilePreviewRepository)repo).DownloadTextContentSnapshotAsync(
            "/docs/readme.txt", bytes.Length, 5 * 1024 * 1024);

        Assert.Equal(content, result.Text);
        Assert.Equal("/docs/readme.txt", api.LastRangePath);
        Assert.Equal(0, api.LastRangeOffset);
        Assert.Equal(bytes.Length, api.LastRangeLength);
    }

    [Fact]
    public async Task DownloadTextContentRejectsContentExceedingMaxBytes()
    {
        var bytes = Encoding.UTF8.GetBytes(new string('X', 2000));
        var api = new TextEditApiClient(
            rangeResponse: bytes,
            totalLength: 2000,
            actualByteCount: 2000);

        var repo = CreateRepository(api);

        await Assert.ThrowsAsync<ArgumentOutOfRangeException>(
            () => ((IFilePreviewRepository)repo).DownloadTextContentSnapshotAsync(
                "/docs/big.txt", 2000, 1000));
    }

    [Fact]
    public async Task DownloadTextContentUsesUtf8BomDetection()
    {
        var text = "Hello, UTF-8 with BOM!";
        var bytes = new byte[] { 0xEF, 0xBB, 0xBF }
            .Concat(Encoding.UTF8.GetBytes(text))
            .ToArray();

        var api = new TextEditApiClient(rangeResponse: bytes, totalLength: bytes.Length);
        var repo = CreateRepository(api);

        var result = await ((IFilePreviewRepository)repo).DownloadTextContentSnapshotAsync(
            "/docs/utf8.txt", bytes.Length, 5 * 1024 * 1024);

        Assert.Equal(text, result.Text);
        Assert.False(result.Text.StartsWith('\uFEFF'));
    }

    [Fact]
    public async Task DownloadTextContentUsesUtf16LeBomDetection()
    {
        var text = "Hello, UTF-16 LE!";
        var bytes = new byte[] { 0xFF, 0xFE }
            .Concat(Encoding.Unicode.GetBytes(text))
            .ToArray();

        var api = new TextEditApiClient(rangeResponse: bytes, totalLength: bytes.Length);
        var repo = CreateRepository(api);

        var result = await ((IFilePreviewRepository)repo).DownloadTextContentSnapshotAsync(
            "/docs/utf16le.txt", bytes.Length, 5 * 1024 * 1024);

        Assert.Equal(text, result.Text);
    }

    [Fact]
    public async Task DownloadTextContentUsesUtf16BeBomDetection()
    {
        var text = "Hello, UTF-16 BE!";
        var bytes = new byte[] { 0xFE, 0xFF }
            .Concat(Encoding.BigEndianUnicode.GetBytes(text))
            .ToArray();

        var api = new TextEditApiClient(rangeResponse: bytes, totalLength: bytes.Length);
        var repo = CreateRepository(api);

        var result = await ((IFilePreviewRepository)repo).DownloadTextContentSnapshotAsync(
            "/docs/utf16be.txt", bytes.Length, 5 * 1024 * 1024);

        Assert.Equal(text, result.Text);
    }

    [Fact]
    public async Task DownloadTextContentThrowsForInvalidUtf8WithoutBom()
    {
        var bytes = new byte[] { 0xFF, 0xFF, 0xFF, 0xFF };
        var api = new TextEditApiClient(rangeResponse: bytes, totalLength: bytes.Length);
        var repo = CreateRepository(api);

        await Assert.ThrowsAsync<InvalidOperationException>(
            () => ((IFilePreviewRepository)repo).DownloadTextContentSnapshotAsync(
                "/docs/bad.txt", bytes.Length, 5 * 1024 * 1024));
    }

    // 通过覆盖上传保存

    [Fact]
    public async Task DownloadSnapshotFreezesExactLengthVersionAndDigest()
    {
        var bytes = Encoding.UTF8.GetBytes("snapshot");
        var api = new TextEditApiClient(rangeResponse: bytes, totalLength: bytes.Length);
        var repo = CreateRepository(api);

        var snapshot = await ((IFilePreviewRepository)repo).DownloadTextContentSnapshotAsync(
            "/docs/snapshot.txt", bytes.Length, 5 * 1024 * 1024);

        Assert.Equal("snapshot", snapshot.Text);
        Assert.Equal(bytes.Length, snapshot.ByteLength);
        Assert.Equal("\"text-v1\"", snapshot.ContentVersion);
        Assert.Equal(
            Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant(),
            snapshot.Sha256);
        Assert.Equal(bytes.Length, api.LastRangeLength);
    }

    [Fact]
    public async Task SafeSaveRejectsChangedSourceBeforeUpload()
    {
        var originalBytes = Encoding.UTF8.GetBytes("original");
        var changedBytes = Encoding.UTF8.GetBytes("changed!");
        var api = new TextEditApiClient(rangeResponse: changedBytes, totalLength: changedBytes.Length);
        var repo = CreateRepository(api);
        var original = new FileTextContentSnapshot(
            "original",
            originalBytes.Length,
            "\"text-v1\"",
            Convert.ToHexString(SHA256.HashData(originalBytes)).ToLowerInvariant());

        var result = await ((IFilePreviewRepository)repo).SaveTextContentAsync(
            "/docs/notes.txt", "updated!", original);

        Assert.Equal(MutationResultStatus.ConfirmedFailure, result.Status);
        Assert.Equal(MutationErrorCategory.Conflict, result.ErrorCategory);
        Assert.Equal(0, api.UploadCount);
    }

    [Fact]
    public async Task SafeSaveConfirmsUploadedBytesByDigest()
    {
        var originalBytes = Encoding.UTF8.GetBytes("original");
        var updatedBytes = Encoding.UTF8.GetBytes("updated!");
        var api = new TextEditApiClient(
            rangeResponses: [originalBytes, updatedBytes],
            uploadResult: new FileUploadTransportResult(FileUploadTransportStatus.Accepted),
            pages: new Dictionary<int, JsonObject>
            {
                [0] = UploadPage(0, 1, UploadItem("/docs", "notes.txt", updatedBytes.Length)),
            });
        var repo = CreateRepository(api);
        var original = new FileTextContentSnapshot(
            "original",
            originalBytes.Length,
            "\"text-v1\"",
            Convert.ToHexString(SHA256.HashData(originalBytes)).ToLowerInvariant());

        var result = await ((IFilePreviewRepository)repo).SaveTextContentAsync(
            "/docs/notes.txt", "updated!", original);

        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Status);
        Assert.Equal(1, api.UploadCount);
    }

    [Fact]
    public async Task ViewModelKeepsUnknownSaveBlockedForReview()
    {
        var originalBytes = Encoding.UTF8.GetBytes("original");
        var api = new TextEditApiClient(
            rangeResponses: [originalBytes, originalBytes, originalBytes],
            uploadResult: new FileUploadTransportResult(FileUploadTransportStatus.Accepted),
            readbackError: new InvalidOperationException("simulated"));
        var repo = CreateRepository(api);
        using var viewModel = new FileTextEditViewModel();
        viewModel.Attach(
            repo,
            new FileItem(
                "/docs/notes.txt",
                "notes.txt",
                false,
                originalBytes.Length,
                DateTimeOffset.UtcNow,
                null,
                true,
                true));

        Assert.True(await viewModel.EnterEditModeAsync());
        viewModel.EditableText = "updated!";
        await viewModel.SaveAsync();

        Assert.True(viewModel.IsSaveNeedsReview);
        Assert.True(viewModel.HasUnsavedChanges);
        Assert.False(viewModel.CanSubmitSave);
        Assert.Equal(1, api.UploadCount);
    }

    [Fact]
    public async Task SaveTextContentUploadsWithOverwriteTrue()
    {
        var original = "original content";
        var content = "edited content";
        var originalBytes = Encoding.UTF8.GetBytes(original);
        var contentBytes = Encoding.UTF8.GetBytes(content);
        var api = new TextEditApiClient(
            rangeResponses: [originalBytes, contentBytes],
            uploadResult: new FileUploadTransportResult(FileUploadTransportStatus.Accepted),
            pages: new Dictionary<int, JsonObject>
            {
                [0] = UploadPage(0, 1, UploadItem("/docs", "notes.txt", contentBytes.Length)),
            });

        var repo = CreateRepository(api);

        var result = await ((IFilePreviewRepository)repo).SaveTextContentAsync(
            "/docs/notes.txt",
            content,
            Snapshot(original));

        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Status);
        Assert.True(result.Submitted);
        Assert.Equal(1, api.UploadCount);
        Assert.True(api.LastUploadOverwrite);
        Assert.Equal("notes.txt", api.LastUploadFileName);
        Assert.Equal("/docs", api.LastUploadFolderPath);
    }

    [Fact]
    public async Task SaveTextContentOnUnverifiedRemainsSubmitted()
    {
        var original = "original content";
        var content = "edited content";
        var originalBytes = Encoding.UTF8.GetBytes(original);
        var api = new TextEditApiClient(
            rangeResponses: [originalBytes, originalBytes],
            uploadResult: new FileUploadTransportResult(FileUploadTransportStatus.Accepted),
            readbackError: new InvalidOperationException("simulated"));

        var repo = CreateRepository(api);

        var result = await ((IFilePreviewRepository)repo).SaveTextContentAsync(
            "/docs/notes.txt",
            content,
            Snapshot(original));

        Assert.Equal(MutationResultStatus.SubmittedButUnverified, result.Status);
        Assert.True(result.Submitted);
        Assert.True(result.RequiresRefresh);
        Assert.Equal(1, result.Counts.Unknown);
    }

    [Fact]
    public async Task SaveTextContentOnCancellationReturnsCancelledBeforeSubmission()
    {
        var original = "original content";
        var content = "edited content";
        var originalBytes = Encoding.UTF8.GetBytes(original);
        var api = new TextEditApiClient(
            rangeResponse: originalBytes,
            totalLength: originalBytes.Length,
            uploadResult: new FileUploadTransportResult(
                FileUploadTransportStatus.CancelledBeforeSubmission));

        var repo = CreateRepository(api);

        var result = await ((IFilePreviewRepository)repo).SaveTextContentAsync(
            "/docs/notes.txt",
            content,
            Snapshot(original));

        Assert.Equal(MutationResultStatus.CancelledBeforeSubmission, result.Status);
        Assert.False(result.Submitted);
    }

    [Fact]
    public async Task SaveTextContentTreatsThrownUploadCancellationAsSubmittedButUnverified()
    {
        var original = "original content";
        var originalBytes = Encoding.UTF8.GetBytes(original);
        var api = new TextEditApiClient(
            rangeResponse: originalBytes,
            uploadError: new OperationCanceledException());
        var repo = CreateRepository(api);

        var result = await ((IFilePreviewRepository)repo).SaveTextContentAsync(
            "/docs/notes.txt",
            "edited content",
            Snapshot(original));

        Assert.Equal(MutationResultStatus.SubmittedButUnverified, result.Status);
        Assert.True(result.Submitted);
        Assert.True(result.RequiresRefresh);
        Assert.Equal(1, result.Counts.Unknown);
        Assert.Equal(1, api.UploadCount);
    }

    // 格式化 JSON、XML、JavaScript、TypeScript 和 CSS

    [Fact]
    public void FormatJsonPrettyPrints()
    {
        var input = "{\"a\":1,\"b\":[2,3]}";
        var result = FileTextFormatter.Format(input, TextFormatKind.Json);

        Assert.Contains("\n", result);
        Assert.Contains("  ", result);
        var reparsed = System.Text.Json.JsonDocument.Parse(result);
        Assert.Equal(1, reparsed.RootElement.GetProperty("a").GetInt32());
    }

    [Fact]
    public void FormatXmlIndents()
    {
        var input = "<root><child attr=\"val\">text</child></root>";
        var result = FileTextFormatter.Format(input, TextFormatKind.Xml);

        Assert.Contains("\n", result);
        Assert.Contains("  ", result);
        Assert.Contains("<child", result);
    }

    [Fact]
    public void FormatJavaScriptIndentsBraces()
    {
        var input = "function foo(){if(true){return 1;}}";
        var result = FileTextFormatter.Format(input, TextFormatKind.JavaScript);

        // 左花括号应与函数声明同行，函数体应缩进。
        Assert.Contains("\n", result);
        Assert.Contains("  ", result);
    }

    [Fact]
    public void FormatCssIndentsBraces()
    {
        var input = "body{margin:0;padding:0}";
        var result = FileTextFormatter.Format(input, TextFormatKind.Css);

        Assert.Contains("\n", result);
        Assert.Contains("  ", result);
        Assert.Contains("margin", result);
    }

    [Fact]
    public void FormatInvalidJsonThrows()
    {
        Assert.ThrowsAny<System.Text.Json.JsonException>(
            () => FileTextFormatter.Format("not json", TextFormatKind.Json));
    }

    // 扩展名白名单

    [Theory]
    [InlineData("json", true, true, TextFormatKind.Json)]
    [InlineData("xml", true, true, TextFormatKind.Xml)]
    [InlineData("js", true, true, TextFormatKind.JavaScript)]
    [InlineData("ts", true, true, TextFormatKind.TypeScript)]
    [InlineData("css", true, true, TextFormatKind.Css)]
    [InlineData("txt", true, false, null)]
    [InlineData("md", true, false, null)]
    [InlineData("py", true, false, null)]
    [InlineData("exe", false, false, null)]
    [InlineData("jpg", false, false, null)]
    [InlineData("", false, false, null)]
    public void CanEditAndFormatByExtension(
        string extension,
        bool expectedCanEdit,
        bool expectedCanFormat,
        TextFormatKind? expectedFormatKind)
    {
        var canEdit = FileTextEditClassification.CanEditSelectedText(extension);
        var canFormat = FileTextEditClassification.CanFormatSelectedText(extension);
        var formatKind = FileTextEditClassification.FormatKindForExtension(extension);

        Assert.Equal(expectedCanEdit, canEdit);
        Assert.Equal(expectedCanFormat, canFormat);
        Assert.Equal(expectedFormatKind, formatKind);
    }

    // 格式化时保留注释和字符串

    [Fact]
    public void FormatBraceLanguageSkipsBracesInStrings()
    {
        var input = "x = \"{not a brace}\"; y = '}'; z = `{template}`;";
        var result = FileTextFormatter.Format(input, TextFormatKind.JavaScript);

        Assert.Contains("\"{not a brace}\"", result);
        Assert.Contains("'}';", result);
        Assert.Contains("`{template}`", result);
    }

    [Fact]
    public void FormatBraceLanguageSkipsBracesInLineComments()
    {
        var input = "x = 1; // {not a brace\n y = 2;";
        var result = FileTextFormatter.Format(input, TextFormatKind.JavaScript);

        Assert.Contains("// {not a brace", result);
    }

    [Fact]
    public void FormatBraceLanguageSkipsBracesInBlockComments()
    {
        var input = "x = 1; /* {not a brace */ y = 2;";
        var result = FileTextFormatter.Format(input, TextFormatKind.JavaScript);

        Assert.Contains("/* {not a brace */", result);
    }

    // 未保存更改保护

    [Fact]
    public void ViewModelHasUnsavedChangesWhenContentDiffers()
    {
        // 编辑状态下文本与原文不同时，必须保留未保存更改保护。
        var viewModelSrc = Read(
            "windows/src/LanStash.App/Features/Files/Preview/FileTextEditViewModel.cs");

        Assert.Contains("HasUnsavedChanges", viewModelSrc);
        Assert.Contains("_editableText", viewModelSrc);
        Assert.Contains("_originalText", viewModelSrc);
        Assert.Contains("FileTextEditState.Editing", viewModelSrc);
        Assert.Contains("StringComparison.Ordinal", viewModelSrc);
    }

    [Fact]
    public void PaneExposesUnsavedCheckForNavigationGuard()
    {
        var pane = Read("windows/src/LanStash.App/Views/FilePreviewPane.xaml.cs");

        Assert.Contains("HasUnsavedTextEdits", pane);
        Assert.Contains("UnsavedDiscardRequested", pane);
        Assert.Contains("ConfirmDiscardTextEdits", pane);
    }

    [Fact]
    public void PaneRequiresConfirmationBeforeReplacingRemoteText()
    {
        var pane = Read("windows/src/LanStash.App/Views/FilePreviewPane.xaml.cs");

        Assert.Contains("FileTextEdit_SaveConfirmTitle", pane);
        Assert.Contains("FileTextEdit_SaveConfirmMessage", pane);
        Assert.Contains("FileTextEdit_SaveConfirmAction", pane);
        Assert.Contains("ContentDialogButton.Close", pane);
    }

    [Fact]
    public void FilesPageChecksUnsavedBeforeNavigation()
    {
        var source = Read("windows/src/LanStash.App/Views/FilesPage.xaml.cs");

        Assert.Contains("HasUnsavedTextEdits", source);
        Assert.Contains("ShowUnsavedDiscardDialogAsync", source);
        Assert.Contains("ConfirmDiscardTextEdits", source);
        Assert.Contains("PreviewPane.UnsavedDiscardRequested", source);
    }

    // 编码检测

    [Fact]
    public void TextDecoderStripsUtf8Bom()
    {
        var source = Read(
            "windows/src/LanStash.Infrastructure/Features/Files/DsmRepository.FileTextEdit.cs");

        Assert.Contains("0xEF, 0xBB, 0xBF", source);
        Assert.Contains("Encoding.UTF8.GetString(bytes[3..])", source);
    }

    [Fact]
    public void TextDecoderStripsUtf16LeBom()
    {
        var source = Read(
            "windows/src/LanStash.Infrastructure/Features/Files/DsmRepository.FileTextEdit.cs");

        Assert.Contains("0xFF, 0xFE", source);
        Assert.Contains("Encoding.Unicode.GetString(bytes[2..])", source);
    }

    [Fact]
    public void TextDecoderStripsUtf16BeBom()
    {
        var source = Read(
            "windows/src/LanStash.Infrastructure/Features/Files/DsmRepository.FileTextEdit.cs");

        Assert.Contains("0xFE, 0xFF", source);
        Assert.Contains("Encoding.BigEndianUnicode.GetString(bytes[2..])", source);
    }

    // XAML 契约检查

    [Fact]
    public void PaneXamlHasTextEditControls()
    {
        var xaml = Read("windows/src/LanStash.App/Views/FilePreviewPane.xaml");

        Assert.Contains("TextEditButton", xaml);
        Assert.Contains("TextEditBox", xaml);
        Assert.Contains("TextEditToolbar", xaml);
        Assert.Contains("TextEditSaveButton", xaml);
        Assert.Contains("TextEditCancelButton", xaml);
        Assert.Contains("TextEditFormatButton", xaml);
        Assert.Contains("TextEditSaveStatus", xaml);
        Assert.Contains("AcceptsReturn=\"True\"", xaml);
    }

    [Fact]
    public void XamlUsesUidForAllTextEditButtons()
    {
        var xaml = Read("windows/src/LanStash.App/Views/FilePreviewPane.xaml");

        Assert.Contains("x:Uid=\"FileTextEdit_EditButton\"", xaml);
        Assert.Contains("x:Uid=\"FileTextEdit_SaveButton\"", xaml);
        Assert.Contains("x:Uid=\"FileTextEdit_CancelButton\"", xaml);
        Assert.Contains("x:Uid=\"FileTextEdit_FormatButton\"", xaml);
    }

    [Fact]
    public void ResourceEntriesExistForBothLocales()
    {
        var en = Read("windows/src/LanStash.App/Strings/en-US/Resources.resw");
        var zh = Read("windows/src/LanStash.App/Strings/zh-CN/Resources.resw");

        foreach (var key in new[]
        {
            "FileTextEdit_EditButton",
            "FileTextEdit_SaveButton",
            "FileTextEdit_CancelButton",
            "FileTextEdit_FormatButton",
            "FileTextEdit_Saving",
            "FileTextEdit_SavedMessage",
            "FileTextEdit_SaveFailedMessage",
            "FileTextEdit_NeedsReviewTitle",
            "FileTextEdit_NeedsReviewMessage",
            "FileTextEdit_SaveConfirmTitle",
            "FileTextEdit_SaveConfirmMessage",
            "FileTextEdit_SaveConfirmAction",
            "FileTextEdit_UnsavedTitle",
            "FileTextEdit_UnsavedMessage",
        })
        {
            Assert.Contains(key, en);
            Assert.Contains(key, zh);
        }
    }

    // 辅助方法

    private static DsmRepository CreateRepository(TextEditApiClient api)
    {
        var capabilities = new[]
        {
            new ApiCapability("SYNO.FileStation.Download", "entry.cgi", 1, 2, "FORM"),
            new ApiCapability("SYNO.FileStation.Upload", "entry.cgi", 1, 2, "MULTIPART"),
            new ApiCapability("SYNO.FileStation.List", "entry.cgi", 1, 2, "FORM"),
        }.ToDictionary(item => item.Name, StringComparer.Ordinal);

        return new DsmRepository(Profile, Session, api, capabilities);
    }

    private static JsonObject UploadPage(int offset, int total, params JsonObject[] items) => new()
    {
        ["offset"] = offset,
        ["total"] = total,
        ["files"] = new JsonArray(items.Select(item => (JsonNode)item).ToArray()),
    };

    private static JsonObject UploadItem(string folder, string name, long size) => new()
    {
        ["path"] = $"{folder}/{name}",
        ["name"] = name,
        ["isdir"] = false,
        ["size"] = size,
    };

    private static FileTextContentSnapshot Snapshot(string text)
    {
        var bytes = Encoding.UTF8.GetBytes(text);
        return new FileTextContentSnapshot(
            text,
            bytes.Length,
            "\"text-v1\"",
            Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant());
    }

    private static string Read(string path) =>
        File.ReadAllText(Path.Combine(RepositoryRoot(), path));

    private static string RepositoryRoot()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null &&
               !Directory.Exists(Path.Combine(directory.FullName, "windows")))
        {
            directory = directory.Parent;
        }
        return directory?.FullName ?? throw new DirectoryNotFoundException();
    }

    private sealed class TextEditApiClient : IDsmApiClient
    {
        private readonly byte[]? _rangeResponse;
        private readonly Queue<byte[]>? _rangeResponses;
        private readonly long _totalLength;
        private readonly long _actualByteCount;
        private readonly bool _hasExplicitActualByteCount;
        private readonly FileUploadTransportResult? _uploadResult;
        private readonly Exception? _uploadError;
        private readonly IReadOnlyDictionary<int, JsonObject>? _pages;
        private readonly Exception? _readbackError;

        public int UploadCount { get; private set; }
        public bool LastUploadOverwrite { get; private set; }
        public string? LastUploadFileName { get; private set; }
        public string? LastUploadFolderPath { get; private set; }
        public string? LastRangePath { get; private set; }
        public long LastRangeOffset { get; private set; }
        public long LastRangeLength { get; private set; }

        public TextEditApiClient(
            byte[]? rangeResponse = null,
            IReadOnlyList<byte[]>? rangeResponses = null,
            long totalLength = 0,
            long actualByteCount = -1,
            FileUploadTransportResult? uploadResult = null,
            IReadOnlyDictionary<int, JsonObject>? pages = null,
            Exception? readbackError = null,
            Exception? uploadError = null)
        {
            _rangeResponse = rangeResponse;
            _rangeResponses = rangeResponses is null ? null : new Queue<byte[]>(rangeResponses);
            _totalLength = totalLength;
            _actualByteCount = actualByteCount >= 0
                ? actualByteCount
                : rangeResponse?.Length ?? rangeResponses?.FirstOrDefault()?.Length ?? 0;
            _hasExplicitActualByteCount = actualByteCount >= 0;
            _uploadResult = uploadResult;
            _uploadError = uploadError;
            _pages = pages;
            _readbackError = readbackError;
        }

        public Task<FileRangeReadResult> ReadFileRangeResultAsync(
            NasProfile profile,
            DsmSession session,
            ApiCapability capability,
            string remotePath,
            long offset,
            long length,
            string? expectedContentVersion,
            long? expectedTotalLength,
            CancellationToken cancellationToken)
        {
            LastRangePath = remotePath;
            LastRangeOffset = offset;
            LastRangeLength = length;

            var response = _rangeResponses is { Count: > 0 }
                ? _rangeResponses.Dequeue()
                : _rangeResponse;
            if (response is null)
            {
                throw new InvalidOperationException("no range response configured");
            }

            var result = new FileRangeReadResult(
                206,
                offset,
                length,
                offset,
                Math.Min(length, response.LongLength),
                _totalLength > 0 ? _totalLength : response.LongLength,
                _hasExplicitActualByteCount ? _actualByteCount : response.LongLength,
                (byte[])response.Clone(),
                "\"text-v1\"",
                false);

            return Task.FromResult(result);
        }

        public Task<FileUploadTransportResult> UploadFileAsync(
            NasProfile profile,
            DsmSession session,
            ApiCapability capability,
            FileUploadRequest request,
            IProgress<long>? progress = null,
            CancellationToken cancellationToken = default)
        {
            UploadCount++;
            LastUploadOverwrite = request.Overwrite;
            LastUploadFileName = request.FileName;
            LastUploadFolderPath = request.FolderPath;
            if (_uploadError is not null)
            {
                return Task.FromException<FileUploadTransportResult>(_uploadError);
            }
            return Task.FromResult(_uploadResult
                ?? new FileUploadTransportResult(FileUploadTransportStatus.Accepted));
        }

        public Task<JsonObject> CallAsync(
            NasProfile profile,
            DsmSession session,
            ApiCapability capability,
            string method,
            IReadOnlyDictionary<string, string>? parameters = null,
            CancellationToken cancellationToken = default)
        {
            if (_readbackError is not null)
            {
                return Task.FromException<JsonObject>(_readbackError);
            }
            if (_pages is not null && parameters is not null &&
                int.TryParse(parameters["offset"], out var offset))
            {
                return Task.FromResult(_pages[offset].DeepClone().AsObject());
            }
            return Task.FromResult(new JsonObject());
        }

        public Uri GetBaseUri(NasProfile profile) => new("https://nas.invalid");
        public Task<IReadOnlyDictionary<string, ApiCapability>> DiscoverAsync(
            NasProfile profile,
            CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<DsmSession> LoginAsync(
            NasProfile profile,
            string password,
            string? otp,
            CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task LogoutAsync(
            NasProfile profile,
            DsmSession session,
            CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<byte[]> ReadFileRangeAsync(
            NasProfile profile,
            DsmSession session,
            ApiCapability capability,
            string remotePath,
            long offset,
            long length,
            CancellationToken cancellationToken = default) => throw new NotSupportedException();
    }
}
