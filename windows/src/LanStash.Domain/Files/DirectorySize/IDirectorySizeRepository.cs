namespace LanStash.Domain;

public interface IDirectorySizeRepository
{
    Guid ProfileId { get; }
    DirectorySizeAvailability Availability { get; }

    Task<DirectorySizeResult> CalculateDirectorySizeAsync(
        string absolutePath,
        CancellationToken cancellationToken = default);
}
