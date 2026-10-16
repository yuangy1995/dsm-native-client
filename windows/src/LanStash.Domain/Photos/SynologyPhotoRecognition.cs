namespace LanStash.Domain;

public enum SynologyPhotoRecognitionKind { RenamePerson, MergePeople, ShowPeople, RemovePersonFaces, ReassignPersonFaces, SetPersonCover, ManualFaces, ShowConcepts, SetConceptCover, RemoveConceptPhotos, SimilarTopPick, SimilarRemove, SimilarUngroup, SimilarUndo }
public sealed record SynologyPhotoConcept(SynologyPhotoCollection Concept, bool Visible, int? DisplayThreshold = null)
{
    public bool AppearsInList => Visible && (Concept.Count is not { } count || DisplayThreshold is not { } threshold || count >= threshold);
}
public sealed record SynologyPhotoPerson(SynologyPhotoCollection Person, bool? Visible = null);
public sealed record SynologyPhotoFace(long Id, long PersonId, SynologyPhoto Photo, SynologyPhotoThumbnail? Thumbnail = null);
public sealed record SynologyPhotoRecognitionEdit(SynologyPhotoRecognitionKind Kind, IReadOnlyList<SynologyPhotoPerson> People)
{
    public SynologyPhotoSpace Space { get; init; }
    public string? Name { get; init; }
    public bool Visible { get; init; }
    public IReadOnlyList<SynologyPhotoFace> Faces { get; init; } = [];
    public SynologyPhoto? CoverPhoto { get; init; }
    public SynologyPhoto? ManualPhoto { get; init; }
    public IReadOnlyList<SynologyPhotoFaceRegion> OriginalRegions { get; init; } = [];
    public IReadOnlyList<SynologyPhotoFaceChange> FaceChanges { get; init; } = [];
    public IReadOnlyList<SynologyPhotoConcept> Concepts { get; init; } = [];
    public IReadOnlyList<SynologyPhoto> ConceptPhotos { get; init; } = [];
    public IReadOnlyList<SynologyPhotoSimilarDetail> SimilarGroups { get; init; } = [];
    public IReadOnlyList<long> SimilarSelection { get; init; } = [];
    public Guid? UndoOperationId { get; init; }
}
public sealed record SynologyPhotoRecognitionSafety(bool MergePeople = false, bool CorrectFaces = false, bool RemoveConceptPhotos = false, bool SimilarGroups = false);
public sealed record SynologyPhotoRecognitionChange(Guid Id, SynologyPhotoRecognitionKind Kind, SynologyPhotoSpace Space,
    SynologyPhotoChangeState State, SynologyPhotoFailure? Failure, bool Running, bool CanContinue, bool NeedsInput,
    int TotalCount, IReadOnlyList<long> CompletedIds, IReadOnlyList<SynologyPhotoPerson> People, IReadOnlyList<long> RemovedIds)
{
    public bool Pending => State is SynologyPhotoChangeState.Submitting or SynologyPhotoChangeState.PendingReview;
    public IReadOnlyList<long> TargetIds { get; init; } = [];
    public IReadOnlyList<long> PhotoIds { get; init; } = [];
    public IReadOnlyList<long> RemovedPhotoIds { get; init; } = [];
    public IReadOnlyList<string> CompletedFaceChanges { get; init; } = [];
    public IReadOnlyList<SynologyPhotoConcept> Concepts { get; init; } = [];
    public IReadOnlyList<SynologyPhotoSimilarResult> SimilarGroups { get; init; } = [];
    public bool CanUndo { get; init; }
    public Guid? UndoOperationId { get; init; }
    public int CompletedCount => Kind == SynologyPhotoRecognitionKind.ManualFaces ? CompletedFaceChanges.Count : CompletedIds.Count;
}
