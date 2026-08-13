using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

/// <summary>
/// File Station MD5 只读计算适配器。SYNO.FileStation.MD5 start → status 轮询 → 十六进制结果，
/// 复用 DirectorySize 的 taskid 轮询与 stop 清理模式。
/// </summary>
public sealed partial class DsmRepository
{
    private const string FileMD5Api = "SYNO.FileStation.MD5";
    private const int FileMD5Version = 2;
    internal int FileMD5PollLimit { get; init; } = 30;
    internal TimeSpan FileMD5InitialPollDelay { get; init; } =
        TimeSpan.FromMilliseconds(250);
    internal TimeSpan FileMD5MaximumPollDelay { get; init; } =
        TimeSpan.FromSeconds(2);
    private static readonly TimeSpan FileMD5StopTimeout = TimeSpan.FromSeconds(2);
    private static readonly TimeSpan FileMD5StartTimeout = TimeSpan.FromSeconds(15);
    private static readonly object ActiveFileMD5Sync = new();
    private static readonly HashSet<Guid> ActiveFileMD5Profiles = [];

    public FileMD5Availability FileMD5Availability =>
        new(FileMD5CapabilityAvailable,
            FileMD5CapabilityAvailable ? FileMD5Version : null);

    FileMD5Availability IFilePreviewRepository.MD5Availability => FileMD5Availability;

    public async Task<string> CalculateMD5Async(
        string path,
        CancellationToken cancellationToken = default)
    {
        var normalizedPath = NormalizeFileMD5Path(path);
        if (!FileMD5CapabilityAvailable)
        {
            throw FileMD5Error(FileMD5Failure.Unsupported);
        }

        lock (ActiveFileMD5Sync)
        {
            if (!ActiveFileMD5Profiles.Add(_profile.Id))
            {
                throw FileMD5Error(FileMD5Failure.AlreadyRunning);
            }
        }

        try
        {
            cancellationToken.ThrowIfCancellationRequested();
            var capability = FixedFileMD5Capability();
            JsonObject start;
            try
            {
                using var startTimeout = new CancellationTokenSource(FileMD5StartTimeout);
                start = await _api.CallAsync(
                    _profile,
                    _session,
                    capability,
                    "start",
                    new Dictionary<string, string>(StringComparer.Ordinal)
                    {
                        ["file_path"] = normalizedPath,
                    },
                    startTimeout.Token).ConfigureAwait(false);
            }
            catch (Exception)
            {
                throw FileMD5Error(FileMD5Failure.PollingFailed);
            }

            if (!TryReadSafeFileMD5TaskId(start, out var taskId))
            {
                throw FileMD5Error(FileMD5Failure.InvalidResponse);
            }

            var taskFinished = false;
            try
            {
                cancellationToken.ThrowIfCancellationRequested();
                for (var attempt = 0; attempt < FileMD5PollLimit; attempt++)
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    var status = await _api.CallAsync(
                        _profile,
                        _session,
                        capability,
                        "status",
                        new Dictionary<string, string>(StringComparer.Ordinal)
                        {
                            ["taskid"] = taskId,
                        },
                        cancellationToken).ConfigureAwait(false);

                    if (!TryReadNativeBoolean(status, "finished", out var finished))
                    {
                        throw FileMD5Error(FileMD5Failure.InvalidResponse);
                    }
                    if (finished)
                    {
                        taskFinished = true;
                        return ParseCompletedFileMD5(status);
                    }
                    if (attempt + 1 < FileMD5PollLimit)
                    {
                        await Task.Delay(FileMD5PollDelay(attempt), cancellationToken)
                            .ConfigureAwait(false);
                    }
                }

                throw FileMD5Error(FileMD5Failure.Timeout);
            }
            catch (OperationCanceledException)
            {
                if (!taskFinished)
                {
                    await StopFileMD5BestEffortAsync(capability, taskId).ConfigureAwait(false);
                }
                throw;
            }
            catch (FileMD5Exception)
            {
                if (!taskFinished)
                {
                    await StopFileMD5BestEffortAsync(capability, taskId).ConfigureAwait(false);
                }
                throw;
            }
            catch (Exception)
            {
                if (!taskFinished)
                {
                    await StopFileMD5BestEffortAsync(capability, taskId).ConfigureAwait(false);
                }
                throw FileMD5Error(FileMD5Failure.PollingFailed);
            }
        }
        finally
        {
            lock (ActiveFileMD5Sync)
            {
                ActiveFileMD5Profiles.Remove(_profile.Id);
            }
        }
    }

    private bool FileMD5CapabilityAvailable =>
        _capabilities.TryGetValue(FileMD5Api, out var capability) &&
        capability.Name == FileMD5Api &&
        capability.MinVersion <= FileMD5Version &&
        capability.MaxVersion >= FileMD5Version &&
        string.Equals(capability.RequestFormat, "FORM", StringComparison.OrdinalIgnoreCase);

    private ApiCapability FixedFileMD5Capability() =>
        _capabilities[FileMD5Api] with
        {
            MinVersion = FileMD5Version,
            MaxVersion = FileMD5Version,
        };

    private async Task StopFileMD5BestEffortAsync(ApiCapability capability, string taskId)
    {
        try
        {
            using var timeout = new CancellationTokenSource(FileMD5StopTimeout);
            await _api.CallAsync(
                _profile,
                _session,
                capability,
                "stop",
                new Dictionary<string, string>(StringComparer.Ordinal)
                {
                    ["taskid"] = taskId,
                },
                timeout.Token).ConfigureAwait(false);
        }
        catch (Exception)
        {
            // stop 只做一次尽力清理，不能遮盖原始取消、超时或轮询错误。
        }
    }

    private static string ParseCompletedFileMD5(JsonObject status)
    {
        var digest = status["md5"] is JsonValue node &&
            node.TryGetValue<string>(out var candidate) &&
            !string.IsNullOrWhiteSpace(candidate)
                ? candidate.Trim().ToLowerInvariant()
                : null;
        if (digest is null ||
            digest.Length != 32 ||
            digest.Any(character => !Uri.IsHexDigit(character)))
        {
            throw FileMD5Error(FileMD5Failure.InvalidResponse);
        }
        return digest;
    }

    private static string NormalizeFileMD5Path(string value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            throw FileMD5Error(FileMD5Failure.InvalidPath);
        }
        var trimmed = value.Trim();
        if (!trimmed.StartsWith("/", StringComparison.Ordinal) ||
            trimmed.Length > 4096 ||
            trimmed.Any(char.IsControl) ||
            trimmed.Contains('\\') ||
            trimmed.EndsWith('/'))
        {
            throw FileMD5Error(FileMD5Failure.InvalidPath);
        }

        var components = trimmed.Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (components.Length == 0 ||
            components.Any(component => component is "." or ".."))
        {
            throw FileMD5Error(FileMD5Failure.InvalidPath);
        }
        return "/" + string.Join('/', components);
    }

    private static bool TryReadSafeFileMD5TaskId(JsonObject start, out string taskId)
    {
        taskId = string.Empty;
        if (start["taskid"] is not JsonValue node ||
            !node.TryGetValue<string>(out var candidate) ||
            string.IsNullOrEmpty(candidate) ||
            candidate.Length > 256 ||
            candidate.Any(character =>
                !char.IsAsciiLetterOrDigit(character) && character is not ('.' or '_' or '-' or ':')))
        {
            return false;
        }
        taskId = candidate;
        return true;
    }

    private TimeSpan FileMD5PollDelay(int attempt)
    {
        if (FileMD5InitialPollDelay <= TimeSpan.Zero)
        {
            return TimeSpan.Zero;
        }
        var multiplier = Math.Pow(2, Math.Min(attempt, 30));
        var milliseconds = Math.Min(
            FileMD5MaximumPollDelay.TotalMilliseconds,
            FileMD5InitialPollDelay.TotalMilliseconds * multiplier);
        return TimeSpan.FromMilliseconds(Math.Max(milliseconds, 0));
    }

    private static FileMD5Exception FileMD5Error(FileMD5Failure failure) => new(failure);
}
