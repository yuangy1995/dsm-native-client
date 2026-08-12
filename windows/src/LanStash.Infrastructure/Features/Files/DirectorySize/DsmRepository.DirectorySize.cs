using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private const string DirectorySizeApi = "SYNO.FileStation.DirSize";
    private const int DirectorySizeVersion = 2;
    internal int DirectorySizePollLimit { get; init; } = 30;
    internal TimeSpan DirectorySizeInitialPollDelay { get; init; } =
        TimeSpan.FromMilliseconds(250);
    internal TimeSpan DirectorySizeMaximumPollDelay { get; init; } =
        TimeSpan.FromSeconds(2);
    private static readonly TimeSpan DirectorySizeStopTimeout = TimeSpan.FromSeconds(2);
    private static readonly object ActiveDirectorySizesSync = new();
    private static readonly HashSet<DirectorySizeReservation> ActiveDirectorySizes = [];

    public DirectorySizeAvailability DirectorySizeAvailability =>
        new(DirectorySizeCapabilityAvailable,
            DirectorySizeCapabilityAvailable ? DirectorySizeVersion : null);

    DirectorySizeAvailability IDirectorySizeRepository.Availability =>
        DirectorySizeAvailability;

    public async Task<DirectorySizeResult> CalculateDirectorySizeAsync(
        string absolutePath,
        CancellationToken cancellationToken = default)
    {
        var normalizedPath = NormalizeDirectorySizePath(absolutePath);
        if (!DirectorySizeCapabilityAvailable)
        {
            throw DirectorySizeError(DirectorySizeFailure.Unsupported);
        }

        var reservation = new DirectorySizeReservation(_profile.Id, normalizedPath);
        lock (ActiveDirectorySizesSync)
        {
            if (!ActiveDirectorySizes.Add(reservation))
            {
                throw DirectorySizeError(DirectorySizeFailure.AlreadyRunning);
            }
        }

        try
        {
            cancellationToken.ThrowIfCancellationRequested();
            var capability = FixedDirectorySizeCapability();
            JsonObject start;
            try
            {
                start = await _api.CallAsync(
                    _profile,
                    _session,
                    capability,
                    "start",
                    new Dictionary<string, string>(StringComparer.Ordinal)
                    {
                        ["path"] = JsonSerializer.Serialize(new[] { normalizedPath }),
                    },
                    cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (Exception)
            {
                throw DirectorySizeError(DirectorySizeFailure.PollingFailed);
            }

            if (!TryReadSafeDirectorySizeTaskId(start, out var taskId))
            {
                throw DirectorySizeError(DirectorySizeFailure.InvalidResponse);
            }

            var taskFinished = false;
            try
            {
                for (var attempt = 0; attempt < DirectorySizePollLimit; attempt++)
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
                        throw DirectorySizeError(DirectorySizeFailure.InvalidResponse);
                    }
                    if (finished)
                    {
                        taskFinished = true;
                        return ParseCompletedDirectorySize(status);
                    }
                    if (attempt + 1 < DirectorySizePollLimit)
                    {
                        await Task.Delay(DirectorySizePollDelay(attempt), cancellationToken)
                            .ConfigureAwait(false);
                    }
                }

                throw DirectorySizeError(DirectorySizeFailure.Timeout);
            }
            catch (OperationCanceledException)
            {
                if (!taskFinished)
                {
                    await StopDirectorySizeBestEffortAsync(capability, taskId)
                        .ConfigureAwait(false);
                }
                throw;
            }
            catch (DirectorySizeException)
            {
                if (!taskFinished)
                {
                    await StopDirectorySizeBestEffortAsync(capability, taskId)
                        .ConfigureAwait(false);
                }
                throw;
            }
            catch (Exception)
            {
                if (!taskFinished)
                {
                    await StopDirectorySizeBestEffortAsync(capability, taskId)
                        .ConfigureAwait(false);
                }
                throw DirectorySizeError(DirectorySizeFailure.PollingFailed);
            }
        }
        finally
        {
            lock (ActiveDirectorySizesSync)
            {
                ActiveDirectorySizes.Remove(reservation);
            }
        }
    }

    private bool DirectorySizeCapabilityAvailable =>
        _capabilities.TryGetValue(DirectorySizeApi, out var capability) &&
        capability.Name == DirectorySizeApi &&
        capability.MinVersion <= DirectorySizeVersion &&
        capability.MaxVersion >= DirectorySizeVersion &&
        string.Equals(capability.RequestFormat, "FORM", StringComparison.OrdinalIgnoreCase);

    private ApiCapability FixedDirectorySizeCapability() =>
        _capabilities[DirectorySizeApi] with
        {
            MinVersion = DirectorySizeVersion,
            MaxVersion = DirectorySizeVersion,
        };

    private async Task StopDirectorySizeBestEffortAsync(
        ApiCapability capability,
        string taskId)
    {
        try
        {
            using var timeout = new CancellationTokenSource(DirectorySizeStopTimeout);
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

    private static DirectorySizeResult ParseCompletedDirectorySize(JsonObject status)
    {
        if (!TryReadNonNegativeInt64(status, "total_size", out var totalBytes) ||
            !TryReadNonNegativeInt64(status, "num_file", out var fileCount) ||
            !TryReadNonNegativeInt64(status, "num_dir", out var directoryCount))
        {
            throw DirectorySizeError(DirectorySizeFailure.InvalidResponse);
        }
        return new DirectorySizeResult(totalBytes, fileCount, directoryCount);
    }

    private static string NormalizeDirectorySizePath(string value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            throw DirectorySizeError(DirectorySizeFailure.InvalidPath);
        }
        var trimmed = value.Trim();
        if (!trimmed.StartsWith("/", StringComparison.Ordinal) ||
            trimmed.Length > 4096 ||
            trimmed.Any(char.IsControl) ||
            trimmed.Contains('\\'))
        {
            throw DirectorySizeError(DirectorySizeFailure.InvalidPath);
        }

        var components = trimmed.Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (components.Length == 0 ||
            components.Any(component => component is "." or ".."))
        {
            throw DirectorySizeError(DirectorySizeFailure.InvalidPath);
        }
        return "/" + string.Join('/', components);
    }

    private static bool TryReadSafeDirectorySizeTaskId(
        JsonObject start,
        out string taskId)
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

    private static bool TryReadNativeBoolean(
        JsonObject value,
        string key,
        out bool result)
    {
        result = false;
        return value[key] is JsonValue node && node.TryGetValue(out result);
    }

    private static bool TryReadNonNegativeInt64(
        JsonObject value,
        string key,
        out long result)
    {
        result = 0;
        if (value[key] is not JsonValue node)
        {
            return false;
        }
        if (node.TryGetValue<long>(out var native))
        {
            result = native;
        }
        else if (node.TryGetValue<int>(out var nativeInt))
        {
            result = nativeInt;
        }
        else if (node.TryGetValue<string>(out var text) &&
            long.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out var parsed))
        {
            result = parsed;
        }
        else
        {
            return false;
        }
        return result >= 0;
    }

    private TimeSpan DirectorySizePollDelay(int attempt)
    {
        if (DirectorySizeInitialPollDelay <= TimeSpan.Zero)
        {
            return TimeSpan.Zero;
        }
        var multiplier = Math.Pow(2, Math.Min(attempt, 30));
        var milliseconds = Math.Min(
            DirectorySizeMaximumPollDelay.TotalMilliseconds,
            DirectorySizeInitialPollDelay.TotalMilliseconds * multiplier);
        return TimeSpan.FromMilliseconds(Math.Max(milliseconds, 0));
    }

    private static DirectorySizeException DirectorySizeError(
        DirectorySizeFailure failure) => new(failure);

    private sealed record DirectorySizeReservation(Guid ProfileId, string NormalizedPath);
}
