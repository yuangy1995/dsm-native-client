namespace LanStash.Domain;

public enum NasZramAlgorithm { Unknown, Lz4, Lzo, Zstd }
public sealed record NasZramSnapshot(bool? IsEnabled, long? ConfiguredBytes, NasZramAlgorithm Algorithm)
{
    public bool HasInformation => IsEnabled is not null || ConfiguredBytes is not null || Algorithm != NasZramAlgorithm.Unknown;
}
