using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private static void VerifyDownloadActionResponse(JsonObject response, string taskId)
    {
        // 官方控制响应可在 success=true 内逐项拒绝，不能只看外层成功标记。
        if (response[DsmApiResponseKeys.RootArray] is not JsonArray items) return;
        if (items.Count != 1 || items[0] is not JsonObject item || item.String("id") != taskId ||
            item["error"] is not JsonValue value || !value.TryGetValue<int>(out var code) || code < 0)
            throw InvalidDownloadStationResponse();
        if (code != 0) throw new DownloadTaskActionRejectedException(code);
    }
    private sealed class DownloadTaskActionRejectedException(int code) : Exception
    {
        public MutationErrorCategory Category => code switch
        { 402 => MutationErrorCategory.Permission, 404 or 405 => MutationErrorCategory.Conflict, _ => MutationErrorCategory.Server };
    }
}
