using System.Collections.Specialized;
using System.Diagnostics;
using LanStash.App.Features.Files;
using LanStash.Domain;
using Xunit.Abstractions;

namespace LanStash.Tests;

public sealed class FileBrowserPerformanceTests(ITestOutputHelper output)
{
    [Fact]
    public async Task TwentyThousandEntriesAppendWithoutRecreatingExistingRows()
    {
        using var model = new FileBrowserViewModel(new SyntheticSource(), pageSize: 1000);
        var clock = Stopwatch.StartNew();
        var allocated = GC.GetTotalAllocatedBytes();
        await model.InitializeAsync();
        var first = model.Items[0];
        var resets = 0;
        var added = 0;
        model.Items.CollectionChanged += (_, args) =>
        {
            if (args.Action == NotifyCollectionChangedAction.Reset) resets++;
            if (args.Action == NotifyCollectionChangedAction.Add) added += args.NewItems!.Count;
        };
        while (model.CanLoadMore) await model.LoadMoreAsync();

        Assert.Equal(20_000, model.Items.Count);
        Assert.Same(first, model.Items[0]);
        Assert.Equal(0, resets);
        Assert.Equal(19_000, added);
        var appendResets = resets;
        model.SetFilter("item-19999");
        Assert.Single(model.Items);
        model.SetFilter(string.Empty);
        Assert.Equal(20_000, model.Items.Count);
        output.WriteLine("合成 20,000 项分页和筛选：{0:F1} ms；分配 {1:F2} MiB；分页 Reset={2}；筛选 Reset={3}。",
            clock.Elapsed.TotalMilliseconds, (GC.GetTotalAllocatedBytes() - allocated) / 1048576.0, appendResets, resets - appendResets);
    }

    private sealed class SyntheticSource : IFileBrowserDataSource
    {
        public Task<FilePage> LoadPageAsync(string path, int offset, int limit, FileListOptions options,
            CancellationToken cancellationToken)
        {
            var items = Enumerable.Range(offset, Math.Min(limit, 20_000 - offset))
                .Select(index => new FileItem($"/synthetic/item-{index:D5}", $"item-{index:D5}",
                    false, index, null, null, false, false)).ToArray();
            return Task.FromResult(new FilePage(items, 20_000, offset));
        }
    }
}
