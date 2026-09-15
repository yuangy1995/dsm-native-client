namespace LanStash.App.Features.Files;

// 仅限页面所属线程使用。权重由实际条目数计算，避免少量超大目录绕过缓存预算。
internal sealed class BoundedLruCache<TKey, TValue> where TKey : notnull
{
    private readonly int _capacity;
    private readonly long _weightLimit;
    private readonly Func<TValue, long> _weight;
    private readonly Dictionary<TKey, LinkedListNode<(TKey Key, TValue Value, long Weight)>> _entries;
    private readonly LinkedList<(TKey Key, TValue Value, long Weight)> _recency = new();

    public BoundedLruCache(int capacity, long weightLimit, Func<TValue, long> weight,
        IEqualityComparer<TKey>? comparer = null)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(capacity, 1);
        ArgumentOutOfRangeException.ThrowIfLessThan(weightLimit, 1);
        ArgumentNullException.ThrowIfNull(weight);
        _capacity = capacity; _weightLimit = weightLimit; _weight = weight;
        _entries = new(comparer);
    }

    public int Count => _entries.Count;
    public long Weight { get; private set; }
    public TValue this[TKey key] { set => Set(key, value); }

    public bool TryGetValue(TKey key, out TValue value)
    {
        if (!_entries.TryGetValue(key, out var node)) { value = default!; return false; }
        _recency.Remove(node); _recency.AddLast(node);
        value = node.Value.Value;
        return true;
    }

    private void Set(TKey key, TValue value)
    {
        var cost = _weight(value);
        ArgumentOutOfRangeException.ThrowIfNegative(cost);
        Remove(key);
        // 超大页面仍由当前浏览器持有，但不再复制进历史缓存。
        if (cost > _weightLimit) return;
        while (_entries.Count >= _capacity || Weight > _weightLimit - cost)
            Remove(_recency.First!.Value.Key);
        var node = _recency.AddLast((key, value, cost));
        _entries.Add(key, node); Weight += cost;
    }

    public bool Remove(TKey key)
    {
        if (!_entries.Remove(key, out var node)) return false;
        _recency.Remove(node); Weight -= node.Value.Weight;
        return true;
    }

    public void Clear() { _entries.Clear(); _recency.Clear(); Weight = 0; }
}
