using System.Security;
using System.Text.Json;

namespace LanStash.App.Features.Chat;

internal interface IChatConversationPinStore
{
    Task<IReadOnlyList<string>> LoadAsync(
        Guid profileId,
        CancellationToken cancellationToken = default);

    Task<bool> SaveAsync(
        Guid profileId,
        IReadOnlyList<string> conversationIds,
        CancellationToken cancellationToken = default);

    Task<bool> RemoveAsync(
        Guid profileId,
        CancellationToken cancellationToken = default);
}

internal sealed class FileChatConversationPinStore : IChatConversationPinStore
{
    internal const int MaximumPinnedConversations = 500;

    private readonly string _directory;

    public FileChatConversationPinStore(string? directory = null) =>
        _directory = Path.GetFullPath(directory ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "LanStash",
            "ChatPins"));

    public async Task<IReadOnlyList<string>> LoadAsync(
        Guid profileId,
        CancellationToken cancellationToken = default)
    {
        try
        {
            var path = PinPath(profileId);
            if (!File.Exists(path))
            {
                return [];
            }
            var stored = JsonSerializer.Deserialize<StoredPins>(
                await File.ReadAllTextAsync(path, cancellationToken).ConfigureAwait(false));
            return Normalize(stored?.ConversationIds ?? []);
        }
        catch (JsonException)
        {
            return [];
        }
        catch (IOException)
        {
            return [];
        }
        catch (UnauthorizedAccessException)
        {
            return [];
        }
        catch (SecurityException)
        {
            return [];
        }
    }

    public async Task<bool> SaveAsync(
        Guid profileId,
        IReadOnlyList<string> conversationIds,
        CancellationToken cancellationToken = default)
    {
        var normalized = Normalize(conversationIds);
        var path = PinPath(profileId);
        var temporaryPath = $"{path}.{Guid.NewGuid():N}.tmp";
        try
        {
            cancellationToken.ThrowIfCancellationRequested();
            Directory.CreateDirectory(_directory);
            await File.WriteAllTextAsync(
                temporaryPath,
                JsonSerializer.Serialize(new StoredPins(1, normalized.ToArray())),
                cancellationToken).ConfigureAwait(false);
            cancellationToken.ThrowIfCancellationRequested();
            File.Move(temporaryPath, path, overwrite: true);
            return true;
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (IOException)
        {
            return false;
        }
        catch (UnauthorizedAccessException)
        {
            return false;
        }
        catch (SecurityException)
        {
            return false;
        }
        finally
        {
            try
            {
                File.Delete(temporaryPath);
            }
            catch (IOException)
            {
                // 每次写入使用唯一临时名；清理失败不会覆盖已提交的置顶状态。
            }
            catch (UnauthorizedAccessException)
            {
                // 每次写入使用唯一临时名；清理失败不会覆盖已提交的置顶状态。
            }
            catch (SecurityException)
            {
                // 每次写入使用唯一临时名；清理失败不会覆盖已提交的置顶状态。
            }
        }
    }

    public Task<bool> RemoveAsync(
        Guid profileId,
        CancellationToken cancellationToken = default)
    {
        try
        {
            cancellationToken.ThrowIfCancellationRequested();
            File.Delete(PinPath(profileId));
            return Task.FromResult(true);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (IOException)
        {
            return Task.FromResult(false);
        }
        catch (UnauthorizedAccessException)
        {
            return Task.FromResult(false);
        }
        catch (SecurityException)
        {
            return Task.FromResult(false);
        }
    }

    internal static IReadOnlyList<string> Normalize(IEnumerable<string?> conversationIds)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var normalized = new List<string>();
        foreach (var value in conversationIds)
        {
            if (normalized.Count >= MaximumPinnedConversations)
            {
                break;
            }
            var id = value?.Trim();
            if (!string.IsNullOrEmpty(id) && seen.Add(id))
            {
                normalized.Add(id);
            }
        }
        return normalized;
    }

    private string PinPath(Guid profileId) =>
        Path.Combine(_directory, $"{profileId:N}.json");

    private sealed record StoredPins(int? Version, string[]? ConversationIds);
}
