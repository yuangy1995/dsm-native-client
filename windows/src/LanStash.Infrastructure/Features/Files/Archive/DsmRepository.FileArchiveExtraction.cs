using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private const int FileArchiveExtractionPollLimit = 8;

    public FileArchiveExtractionAvailability FileArchiveExtractionAvailability =>
        new(
            CanExtract: ArchiveExtractionCapabilityAvailable,
            ExtractVersion: HasArchiveCapability("SYNO.FileStation.Extract", 2) ? 2 : null,
            ListVersion: HasArchiveCapability("SYNO.FileStation.List", 2) ? 2 : null);

    FileArchiveExtractionAvailability IFileArchiveExtractionRepository.Availability =>
        FileArchiveExtractionAvailability;

    public async Task<FileArchiveExtractionOutcome> ExtractAsync(
        FileArchiveExtractionRequest request,
        CancellationToken cancellationToken = default)
    {
        if (!TryNormalizeExtractionRequest(request, out var normalized, out var review,
                out var invalidTag))
            return ExtractionOutcome(MutationResultStatus.ConfirmedFailure, false, false,
                1, 0, 0, MutationErrorCategory.Validation, invalidTag);

        var reservation = ReserveArchiveExtraction(review!);
        if (!reservation.Acquired)
            return ExtractionOutcome(MutationResultStatus.ConfirmedFailure, false, false,
                1, 0, 0, MutationErrorCategory.Conflict,
                "file.archive-extraction.target-busy");

        try
        {
            if (reservation.PendingReview is not null)
                return await ReviewArchiveExtractionAsync(reservation.PendingReview)
                    .ConfigureAwait(false);
            if (!ArchiveExtractionCapabilityAvailable)
                return ExtractionOutcome(MutationResultStatus.Unsupported, false, false,
                    1, 0, 0, MutationErrorCategory.Unsupported,
                    "file.archive-extraction.unsupported");
            if (cancellationToken.IsCancellationRequested)
                return ExtractionOutcome(MutationResultStatus.CancelledBeforeSubmission,
                    false, false, 0, 0, 0, null,
                    "file.archive-extraction.cancelled-before-submit");

            IReadOnlyList<FileArchiveExtractionListedItem> archiveItems;
            try
            {
                archiveItems = await _api.ListFileArchiveExtractionItemsAsync(
                    _profile,
                    _session,
                    _capabilities["SYNO.FileStation.Extract"],
                    normalized.Source.Item.Path,
                    normalized.Options,
                    cancellationToken).ConfigureAwait(false);
                var originalPenalty = FileArchiveExtractionOptions.NamePenalty(archiveItems.Select(item => item.Name));
                if (normalized.Options.Codepage is null && originalPenalty > 0)
                {
                    try
                    {
                        var chineseOptions = normalized.Options with { Codepage = "chs" };
                        var chineseItems = await _api.ListFileArchiveExtractionItemsAsync(_profile, _session,
                            _capabilities["SYNO.FileStation.Extract"], normalized.Source.Item.Path, chineseOptions, cancellationToken).ConfigureAwait(false);
                        if (chineseItems.Count == archiveItems.Count && FileArchiveExtractionOptions.NamePenalty(chineseItems.Select(item => item.Name)) < originalPenalty)
                        {
                            normalized = normalized with { Options = chineseOptions };
                            archiveItems = chineseItems;
                        }
                    }
                    catch (OperationCanceledException) { throw; }
                    catch (DsmException error) when (IsArchiveAuthenticationFailure(error)) { throw; }
                    catch (Exception) { /* 编码比较不可用时使用原始成功列表，不影响原解压流程。 */ }
                }
            }
            catch (DsmException error) when (IsArchiveAuthenticationFailure(error))
            {
                throw;
            }
            catch (OperationCanceledException)
            {
                return ExtractionOutcome(MutationResultStatus.CancelledBeforeSubmission,
                    false, false, 0, 0, 0, null,
                    "file.archive-extraction.cancelled-before-submit");
            }
            catch (NotSupportedException)
            {
                return ExtractionOutcome(MutationResultStatus.Unsupported, false, false,
                    1, 0, 0, MutationErrorCategory.Unsupported,
                    "file.archive-extraction.list-unsupported");
            }
            catch (DsmException error) when (error.Code == 1403)
            {
                return ExtractionOutcome(MutationResultStatus.ConfirmedFailure, false, false,
                    1, 0, 0, MutationErrorCategory.Validation, "file.archive-extraction.password-required");
            }
            catch (Exception)
            {
                return ExtractionOutcome(MutationResultStatus.ConfirmedFailure, false, false,
                    1, 0, 0, MutationErrorCategory.Validation,
                    "file.archive-extraction.archive-list-invalid");
            }

            if (!TryBuildExtractionOutputs(archiveItems, normalized,
                    out var outputs, out var outputTag))
                return ExtractionOutcome(MutationResultStatus.ConfirmedFailure, false, false,
                    Math.Max(1, archiveItems.Count), 0, 0, MutationErrorCategory.Validation,
                    outputTag);
            review = review! with { ExpectedOutputs = outputs,
                Request = normalized with { Options = normalized.Options with { Password = null } } };

            IReadOnlyList<FileArchiveListedItem> folderItems;
            FileArchiveListedItem destination;
            try
            {
                folderItems = await LoadArchiveFolderAsync(normalized.DestinationFolder,
                    cancellationToken).ConfigureAwait(false);
                destination = await LoadArchiveExtractionDestinationAsync(
                    normalized.DestinationFolder, cancellationToken).ConfigureAwait(false);
            }
            catch (DsmException error) when (IsArchiveAuthenticationFailure(error))
            {
                throw;
            }
            catch (OperationCanceledException)
            {
                return ExtractionOutcome(MutationResultStatus.CancelledBeforeSubmission,
                    false, false, 0, 0, 0, null,
                    "file.archive-extraction.cancelled-before-submit");
            }
            catch (Exception)
            {
                return ExtractionOutcome(MutationResultStatus.ConfirmedFailure, false, false,
                    outputs.Count, 0, 0, MutationErrorCategory.Unknown,
                    "file.archive-extraction.preflight-invalid");
            }

            var observedSource = folderItems.SingleOrDefault(item =>
                item.Item.Path == normalized.Source.Item.Path);
            if (observedSource is null ||
                !MatchesArchiveExtractionSource(observedSource, normalized.Source))
                return ExtractionOutcome(MutationResultStatus.ConfirmedFailure, false, false,
                    outputs.Count, 0, 0, MutationErrorCategory.Conflict,
                    "file.archive-extraction.source-changed");
            if (!destination.Item.IsDirectory ||
                destination.Item.Path != normalized.DestinationFolder)
                return ExtractionOutcome(MutationResultStatus.ConfirmedFailure, false, false,
                    outputs.Count, 0, 0, MutationErrorCategory.Conflict,
                    "file.archive-extraction.destination-changed");
            if (!destination.Item.CanWrite)
                return ExtractionOutcome(MutationResultStatus.PermissionDenied, false, false,
                    outputs.Count, 0, 0, MutationErrorCategory.Permission,
                    "file.archive-extraction.destination-read-only");

            try
            {
                if (await CheckExtractionTargetsAsync(normalized, outputs, folderItems, cancellationToken).ConfigureAwait(false) is { } conflict)
                    return ExtractionOutcome(conflict == MutationErrorCategory.Permission ? MutationResultStatus.PermissionDenied : MutationResultStatus.ConfirmedFailure,
                        false, false, outputs.Count, 0, 0, conflict, "file.archive-extraction.target-conflict");
            }
            catch (DsmException error) when (IsArchiveAuthenticationFailure(error)) { throw; }
            catch (OperationCanceledException)
            { return ExtractionOutcome(MutationResultStatus.CancelledBeforeSubmission, false, false, 0, 0, 0, null, "file.archive-extraction.cancelled-before-submit"); }
            catch (Exception)
            { return ExtractionOutcome(MutationResultStatus.ConfirmedFailure, false, false, outputs.Count, 0, 0, MutationErrorCategory.Unknown, "file.archive-extraction.preflight-invalid"); }

            return await SubmitArchiveExtractionAsync(normalized, review, cancellationToken)
                .ConfigureAwait(false);
        }
        catch (DsmException error) when (IsArchiveAuthenticationFailure(error))
        {
            throw;
        }
        finally
        {
            ReleaseArchiveExtraction(review!.ReservedPaths);
        }
    }

    private async Task<FileArchiveExtractionOutcome> SubmitArchiveExtractionAsync(
        FileArchiveExtractionRequest request,
        FileArchiveExtractionReview review,
        CancellationToken cancellationToken)
    {
        FileArchiveExtractionStartTransportResult start;
        try
        {
            start = await _api.StartFileArchiveExtractionAsync(
                _profile,
                _session,
                _capabilities["SYNO.FileStation.Extract"],
                request.Source.Item.Path,
                request.DestinationFolder,
                request.Options,
                cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            return await FinishArchiveExtractionAsync(review, true, false,
                MutationErrorCategory.Network,
                "file.archive-extraction.cancelled-after-submit").ConfigureAwait(false);
        }
        catch (DsmException error) when (IsArchiveAuthenticationFailure(error))
        {
            StoreArchiveExtractionReview(review);
            throw;
        }
        catch (Exception)
        {
            return await FinishArchiveExtractionAsync(review, false, false,
                MutationErrorCategory.Unknown,
                "file.archive-extraction.transport-unverified").ConfigureAwait(false);
        }

        if (start.ErrorCategory == MutationErrorCategory.Authentication)
        {
            StoreArchiveExtractionReview(review);
            throw ArchiveAuthenticationException();
        }
        if (start.Status == FileMutationTransportStatus.CancelledBeforeSubmission)
            return ExtractionOutcome(MutationResultStatus.CancelledBeforeSubmission,
                false, false, 0, 0, 0, start.ErrorCategory, start.DiagnosticTag);
        if (start.Status == FileMutationTransportStatus.Unsupported)
            return ExtractionOutcome(MutationResultStatus.Unsupported, false, false,
                review.ExpectedOutputs.Count, 0, 0, start.ErrorCategory, start.DiagnosticTag);

        var cancellationAfterSubmission =
            start.Status == FileMutationTransportStatus.CancellationRequestedAfterSubmission;
        var confirmedFailure = start.Status == FileMutationTransportStatus.ConfirmedFailure;
        var postSubmitFailure = start.Status != FileMutationTransportStatus.ResponseReceived;
        var taskFinished = false;
        var errorCategory = start.ErrorCategory;
        var diagnosticTag = start.DiagnosticTag;

        if (start.Status == FileMutationTransportStatus.ResponseReceived &&
            ValidArchiveCompressionTaskId(start.TaskId))
        {
            try
            {
                review.TaskId = start.TaskId;
                var taskStatus = await PollArchiveExtractionAsync(
                    start.TaskId!, cancellationToken).ConfigureAwait(false);
                taskFinished =
                    taskStatus.Status == FileArchiveExtractionTaskTransportStatus.Finished;
                confirmedFailure |=
                    taskStatus.Status == FileArchiveExtractionTaskTransportStatus.ConfirmedFailure;
                review.TaskFinished = taskFinished;
                errorCategory ??= taskStatus.ErrorCategory;
                diagnosticTag ??= taskStatus.DiagnosticTag;
                postSubmitFailure = !taskFinished;
            }
            catch (OperationCanceledException)
            {
                cancellationAfterSubmission = true;
                postSubmitFailure = true;
                StoreArchiveExtractionReview(review);
                await StopArchiveExtractionBestEffortAsync(start.TaskId!).ConfigureAwait(false);
            }
            catch (DsmException error) when (IsArchiveAuthenticationFailure(error))
            {
                StoreArchiveExtractionReview(review);
                throw;
            }
            catch (Exception)
            {
                postSubmitFailure = true;
            }
        }
        else if (start.Status == FileMutationTransportStatus.ResponseReceived)
        {
            postSubmitFailure = true;
        }

        return await FinishArchiveExtractionAsync(
            review,
            cancellationAfterSubmission,
            confirmedFailure,
            errorCategory ?? (postSubmitFailure || !taskFinished
                ? MutationErrorCategory.Unknown
                : null),
            diagnosticTag ?? "file.archive-extraction.readback-unverified")
            .ConfigureAwait(false);
    }

    private async Task<FileArchiveExtractionTaskTransportResult> PollArchiveExtractionAsync(
        string taskId,
        CancellationToken cancellationToken)
    {
        for (var attempt = 0; attempt < FileArchiveExtractionPollLimit; attempt++)
        {
            var status = await _api.ReadFileArchiveExtractionStatusAsync(
                _profile,
                _session,
                _capabilities["SYNO.FileStation.Extract"],
                taskId,
                cancellationToken).ConfigureAwait(false);
            if (status.ErrorCategory == MutationErrorCategory.Authentication)
                throw ArchiveAuthenticationException();
            if (status.Status == FileArchiveExtractionTaskTransportStatus.Finished)
                return status;
            if (status.Status != FileArchiveExtractionTaskTransportStatus.Running)
                return status;
            await Task.Delay(TimeSpan.FromMilliseconds(Math.Min(2000, 500 * (1 << attempt))),
                cancellationToken).ConfigureAwait(false);
        }
        return new(FileArchiveExtractionTaskTransportStatus.Running,
            MutationErrorCategory.Unknown,
            "file.archive-extraction.status-timeout");
    }

    private async Task StopArchiveExtractionBestEffortAsync(string taskId)
    {
        try
        {
            var result = await _api.StopFileArchiveExtractionAsync(
                _profile,
                _session,
                _capabilities["SYNO.FileStation.Extract"],
                taskId,
                CancellationToken.None).ConfigureAwait(false);
            if (result.ErrorCategory == MutationErrorCategory.Authentication)
                throw ArchiveAuthenticationException();
        }
        catch (DsmException error) when (IsArchiveAuthenticationFailure(error))
        {
            throw;
        }
        catch (Exception)
        {
            // stop 只用于尽力取消，最终结论仍由独立目录回读给出。
        }
    }

    private async Task<FileArchiveExtractionOutcome> FinishArchiveExtractionAsync(
        FileArchiveExtractionReview review,
        bool cancellationAfterSubmission,
        bool confirmedFailure,
        MutationErrorCategory? errorCategory,
        string? diagnosticTag)
    {
        StoreArchiveExtractionReview(review);
        var readback = await ReadBackArchiveExtractionAsync(review).ConfigureAwait(false);
        // 输出可能是正在写入的部分文件；任务完成前不把存在或类型一致当成成功。
        if (confirmedFailure || !review.TaskFinished)
        {
            if (confirmedFailure && !cancellationAfterSubmission)
            {
                RemoveArchiveExtractionReview(review);
                return ExtractionOutcome(MutationResultStatus.ConfirmedFailure, true, true,
                    review.ExpectedOutputs.Count, 0, 0, errorCategory ?? MutationErrorCategory.Server, diagnosticTag);
            }
            return ExtractionOutcome(cancellationAfterSubmission ? MutationResultStatus.CancellationRequestedAfterSubmission : MutationResultStatus.SubmittedButUnverified,
                true, true, 0, 0, review.ExpectedOutputs.Count, errorCategory ?? MutationErrorCategory.Unknown, diagnosticTag);
        }
        if (readback.ConfirmedItems.Count == review.ExpectedOutputs.Count)
        {
            RemoveArchiveExtractionReview(review);
            return ExtractionOutcome(MutationResultStatus.ConfirmedSuccess, true, true,
                0, readback.ConfirmedItems.Count, 0, null, null,
                readback.ConfirmedItems);
        }
        if (readback.ConfirmedItems.Count > 0)
        {
            return ExtractionOutcome(MutationResultStatus.PartialSuccess, true, true,
                0,
                readback.ConfirmedItems.Count,
                review.ExpectedOutputs.Count - readback.ConfirmedItems.Count,
                errorCategory ?? MutationErrorCategory.Unknown,
                diagnosticTag ?? "file.archive-extraction.partial-readback",
                readback.ConfirmedItems);
        }
        StoreArchiveExtractionReview(review);
        return ExtractionOutcome(
            cancellationAfterSubmission
                ? MutationResultStatus.CancellationRequestedAfterSubmission
                : MutationResultStatus.SubmittedButUnverified,
            true,
            true,
            0,
            0,
            review.ExpectedOutputs.Count,
            errorCategory ?? MutationErrorCategory.Unknown,
            diagnosticTag);
    }

    private async Task<FileArchiveExtractionOutcome> ReviewArchiveExtractionAsync(
        FileArchiveExtractionReview review)
    {
        if (!review.TaskFinished)
        {
            try
            {
                if (review.TaskId is not null)
                {
                    var status = await _api.ReadFileArchiveExtractionStatusAsync(_profile, _session,
                        _capabilities["SYNO.FileStation.Extract"], review.TaskId, CancellationToken.None).ConfigureAwait(false);
                    if (status.ErrorCategory == MutationErrorCategory.Authentication) throw ArchiveAuthenticationException();
                    review.TaskFinished = status.Status == FileArchiveExtractionTaskTransportStatus.Finished;
                    if (status.Status == FileArchiveExtractionTaskTransportStatus.ConfirmedFailure)
                        return await FinishArchiveExtractionAsync(review, false, true, status.ErrorCategory, status.DiagnosticTag).ConfigureAwait(false);
                }
            }
            catch (DsmException error) when (IsArchiveAuthenticationFailure(error)) { throw; }
            catch (Exception) { /* 保留任务与目标锁，稍后只能回读。 */ }
            if (!review.TaskFinished)
                return ExtractionOutcome(MutationResultStatus.SubmittedButUnverified, true, true,
                    0, 0, review.ExpectedOutputs.Count, MutationErrorCategory.Unknown, "file.archive-extraction.review-pending");
        }
        var readback = await ReadBackArchiveExtractionAsync(review).ConfigureAwait(false);
        if (readback.ConfirmedItems.Count == review.ExpectedOutputs.Count)
        {
            RemoveArchiveExtractionReview(review);
            return ExtractionOutcome(MutationResultStatus.ConfirmedSuccess, true, true,
                0, readback.ConfirmedItems.Count, 0, null, null,
                readback.ConfirmedItems);
        }
        if (readback.ConfirmedItems.Count > 0)
            return ExtractionOutcome(MutationResultStatus.PartialSuccess, true, true,
                0, readback.ConfirmedItems.Count,
                review.ExpectedOutputs.Count - readback.ConfirmedItems.Count,
                MutationErrorCategory.Unknown,
                "file.archive-extraction.review-partial");
        return ExtractionOutcome(MutationResultStatus.SubmittedButUnverified, true, true,
            0, 0, review.ExpectedOutputs.Count, MutationErrorCategory.Unknown,
            "file.archive-extraction.review-pending");
    }

    private async Task<FileArchiveExtractionReadback> ReadBackArchiveExtractionAsync(
        FileArchiveExtractionReview review)
    {
        try
        {
            var confirmed = new List<FileItem>();
            foreach (var group in review.ExpectedOutputs.GroupBy(item => ArchiveMutationParent(item.Path)))
            {
                IReadOnlyList<FileArchiveListedItem> folderItems;
                try { folderItems = await LoadArchiveFolderAsync(group.Key, CancellationToken.None).ConfigureAwait(false); }
                catch (DsmException error) when (IsArchiveAuthenticationFailure(error)) { throw; }
                catch (Exception) { continue; }
                var byPath = folderItems.ToDictionary(item => item.Item.Path, StringComparer.Ordinal);
                confirmed.AddRange(group.Where(expected => byPath.TryGetValue(expected.Path, out var observed) &&
                        observed.Item.IsDirectory == expected.IsDirectory &&
                        (expected.IsDirectory || expected.Size is null || observed.Item.Size == expected.Size))
                    .Select(expected => byPath[expected.Path].Item));
            }
            return new FileArchiveExtractionReadback(confirmed);
        }
        catch (DsmException error) when (IsArchiveAuthenticationFailure(error))
        {
            throw;
        }
        catch (Exception)
        {
            return new FileArchiveExtractionReadback([]);
        }
    }

    private async Task<FileArchiveListedItem> LoadArchiveExtractionDestinationAsync(
        string folderPath,
        CancellationToken cancellationToken)
    {
        var data = await _api.CallReadJsonObjectAsync(
            _profile,
            _session,
            _capabilities["SYNO.FileStation.List"],
            2,
            "getinfo",
            new Dictionary<string, string>
            {
                ["path"] = JsonSerializer.Serialize(new[] { folderPath }),
                ["additional"] = "[\"size\",\"time\",\"perm\"]",
            },
            cancellationToken).ConfigureAwait(false);
        if (data["files"] is not JsonArray { Count: 1 } files)
            throw new InvalidDataException("file.archive-extraction.invalid-destination");
        return ParseArchiveListedItem(files[0], ArchiveMutationParent(folderPath));
    }

    private bool TryNormalizeExtractionRequest(
        FileArchiveExtractionRequest request,
        out FileArchiveExtractionRequest normalized,
        out FileArchiveExtractionReview? review,
        out string invalidTag)
    {
        normalized = request;
        review = null;
        invalidTag = "file.archive-extraction.invalid-input";
        if (request is null || request.ProfileId != ProfileId || request.Source is null ||
            request.Options is null || !request.Options.IsValid ||
            request.Options.Overwrite && !request.OverwriteConfirmed ||
            request.Source.Item is null ||
            request.Source.SourceKind != FileArchiveCompressionSourceKind.Local ||
            !request.Source.CanRead || request.Source.Item.IsDirectory ||
            request.Source.Item.Size <= 0 ||
            !ValidArchiveObjectPath(request.Source.Item.Path) ||
            !ValidArchiveItemName(request.Source.Item.Name) ||
            !request.Source.Item.Path.EndsWith("/" + request.Source.Item.Name,
                StringComparison.Ordinal) ||
            ArchiveContainsRecycleSegment(request.Source.Item.Path) ||
            !FileArchiveExtractionOptions.IsSupportedArchive(request.Source.Item.Name) ||
            request.DestinationFolder != ArchiveMutationParent(request.Source.Item.Path) ||
            string.IsNullOrEmpty(request.DestinationFolder))
            return false;

        normalized = request;
        var reservedPaths = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            request.Source.Item.Path,
            request.DestinationFolder,
        };
        var signature = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(
            System.Text.Encoding.UTF8.GetBytes(JsonSerializer.Serialize(request.Options))));
        review = new FileArchiveExtractionReview(normalized with { Options = normalized.Options with { Password = null } }, [], reservedPaths, signature);
        return true;
    }

    private static bool TryBuildExtractionOutputs(
        IReadOnlyList<FileArchiveExtractionListedItem> archiveItems,
        FileArchiveExtractionRequest request,
        out IReadOnlyList<FileArchiveExtractionExpectedOutput> outputs,
        out string invalidTag)
    {
        outputs = [];
        invalidTag = "file.archive-extraction.invalid-archive-item";
        if (archiveItems is null || archiveItems.Count == 0)
        {
            invalidTag = "file.archive-extraction.empty-archive";
            return false;
        }
        var paths = new Dictionary<string, FileArchiveExtractionListedItem>(StringComparer.OrdinalIgnoreCase);
        foreach (var item in archiveItems)
            if (item is null || !ValidArchiveItemName(item.Name) || item.Size < 0 ||
                string.IsNullOrEmpty(item.RelativePath) || item.RelativePath.Contains('\\') ||
                item.RelativePath.Split('/').Any(segment => !ValidArchiveItemName(segment)) ||
                item.RelativePath.Split('/')[^1] != item.Name || !paths.TryAdd(item.RelativePath, item)) return false;
        foreach (var item in archiveItems)
        {
            var separator = item.RelativePath.LastIndexOf('/');
            if (separator >= 0 && (!paths.TryGetValue(item.RelativePath[..separator], out var parent) || !parent.IsDirectory)) return false;
        }
        var destinationFolder = request.DestinationFolder;
        var result = new List<FileArchiveExtractionExpectedOutput>(archiveItems.Count);
        if (request.Options.CreateSubfolder)
        {
            var folderName = Path.GetFileNameWithoutExtension(request.Source.Item.Name);
            if (!ValidArchiveItemName(folderName)) return false;
            destinationFolder += "/" + folderName;
            result.Add(new(folderName, destinationFolder, true));
        }
        var outputPaths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var item in archiveItems)
        {
            if (!request.Options.KeepDirectoryStructure && item.IsDirectory) continue;
            var path = destinationFolder + "/" + (request.Options.KeepDirectoryStructure ? item.RelativePath : item.Name);
            if (!outputPaths.Add(path) || path.Equals(request.Source.Item.Path, StringComparison.OrdinalIgnoreCase)) return false;
            result.Add(new FileArchiveExtractionExpectedOutput(
                item.Name, path, item.IsDirectory, item.Size));
        }
        outputs = result;
        return result.Count > 0;
    }

    private async Task<MutationErrorCategory?> CheckExtractionTargetsAsync(FileArchiveExtractionRequest request,
        IReadOnlyList<FileArchiveExtractionExpectedOutput> outputs, IReadOnlyList<FileArchiveListedItem> rootItems, CancellationToken token)
    {
        var folders = new Dictionary<string, IReadOnlyList<FileArchiveListedItem>>(StringComparer.OrdinalIgnoreCase)
        { [request.DestinationFolder] = rootItems };
        var newFolders = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var output in outputs.OrderBy(item => item.Path.Count(character => character == '/')))
        {
            token.ThrowIfCancellationRequested();
            var parent = ArchiveMutationParent(output.Path);
            if (newFolders.Contains(parent))
            {
                if (output.IsDirectory) newFolders.Add(output.Path);
                continue;
            }
            if (!folders.TryGetValue(parent, out var items))
                folders[parent] = items = await LoadArchiveFolderAsync(parent, token).ConfigureAwait(false);
            var existing = items.SingleOrDefault(item => item.Item.Path.Equals(output.Path, StringComparison.OrdinalIgnoreCase));
            if (existing is null)
            {
                if (output.IsDirectory) newFolders.Add(output.Path);
                continue;
            }
            if (existing.Item.IsDirectory != output.IsDirectory || !output.IsDirectory && !request.Options.Overwrite)
                return MutationErrorCategory.Conflict;
            if (!existing.Item.CanWrite) return MutationErrorCategory.Permission;
        }
        return null;
    }

    private FileArchiveExtractionReservation ReserveArchiveExtraction(
        FileArchiveExtractionReview review)
    {
        var state = ArchiveMutationStateForProfile(ProfileId);
        lock (state.Sync)
        {
            state.ExtractionReviews.TryGetValue(review.Key, out var pending);
            var unresolvedPaths = state.Reviews.Values
                .SelectMany(item => item.ReservedPaths)
                .Concat(state.ExtractionReviews
                    .Where(item => item.Key != review.Key)
                    .SelectMany(item => item.Value.ReservedPaths))
                .ToHashSet(StringComparer.OrdinalIgnoreCase);
            if (review.Request.ProfileId != ProfileId ||
                HasArchivePathConflict(state.ActivePaths, review.ReservedPaths) ||
                HasArchivePathConflict(unresolvedPaths, review.ReservedPaths))
                return new(false, null);
            foreach (var path in review.ReservedPaths)
                state.ActivePaths.Add(path);
            return new(true, pending);
        }
    }

    private void ReleaseArchiveExtraction(IReadOnlySet<string> paths)
    {
        var state = ArchiveMutationStateForProfile(ProfileId);
        lock (state.Sync)
        foreach (var path in paths)
            state.ActivePaths.Remove(path);
    }

    private void StoreArchiveExtractionReview(FileArchiveExtractionReview review)
    {
        var state = ArchiveMutationStateForProfile(ProfileId);
        lock (state.Sync)
            state.ExtractionReviews[review.Key] = review;
    }

    private void RemoveArchiveExtractionReview(FileArchiveExtractionReview review)
    {
        var state = ArchiveMutationStateForProfile(ProfileId);
        lock (state.Sync)
            state.ExtractionReviews.Remove(review.Key);
    }

    private static bool MatchesArchiveExtractionSource(
        FileArchiveListedItem observed,
        FileArchiveExtractionSource expected) =>
        observed.CanRead == expected.CanRead &&
        observed.Item.Path == expected.Item.Path &&
        observed.Item.Name == expected.Item.Name &&
        !observed.Item.IsDirectory &&
        observed.Item.Size == expected.Item.Size &&
        observed.Item.ModifiedAt == expected.Item.ModifiedAt;

    private bool ArchiveExtractionCapabilityAvailable =>
        HasArchiveCapability("SYNO.FileStation.Extract", 2) &&
        HasArchiveCapability("SYNO.FileStation.List", 2);

    private static FileArchiveExtractionOutcome ExtractionOutcome(
        MutationResultStatus status,
        bool submitted,
        bool refresh,
        int failed,
        int succeeded,
        int unknown,
        MutationErrorCategory? errorCategory,
        string? diagnosticTag,
        IReadOnlyList<FileItem>? confirmedItems = null) =>
        new(new MutationResult(1, status, "extractFile", submitted, refresh,
            new MutationResultCounts(succeeded, failed, unknown), errorCategory,
            diagnosticTag: diagnosticTag), confirmedItems);

    private sealed record FileArchiveExtractionExpectedOutput(
        string Name,
        string Path,
        bool IsDirectory,
        long? Size = null);

    private sealed record FileArchiveExtractionReview(
        FileArchiveExtractionRequest Request,
        IReadOnlyList<FileArchiveExtractionExpectedOutput> ExpectedOutputs,
        HashSet<string> ReservedPaths,
        string OptionsSignature)
    {
        public string? TaskId { get; set; }
        public bool TaskFinished { get; set; }
        public string Key => $"{Request.ProfileId:N}|{Request.Source.Item.Path}|" +
            Request.DestinationFolder + "|" + OptionsSignature;
    }

    private sealed record FileArchiveExtractionReservation(
        bool Acquired,
        FileArchiveExtractionReview? PendingReview);

    private sealed record FileArchiveExtractionReadback(
        IReadOnlyList<FileItem> ConfirmedItems);
}
