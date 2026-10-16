using LanStash.Domain;

namespace LanStash.Infrastructure;

/// <summary>公开 Download Station 的通用与任务错误；不能复用 File Station 的同号解释。</summary>
internal static class DownloadStationErrors
{
    internal static bool IsKnownRejection(int? code) => code is >= 101 and <= 107 or 119 or >= 400 and <= 408;
    internal static MutationErrorCategory Category(int? code) => code switch
    {
        105 or 402 => MutationErrorCategory.Permission,
        106 or 107 or 119 => MutationErrorCategory.Authentication,
        102 or 103 or 104 => MutationErrorCategory.Unsupported,
        404 or 405 => MutationErrorCategory.Conflict,
        _ => MutationErrorCategory.Server,
    };
}
