using LanStash.Domain;
using static LanStash.Infrastructure.SynologyPhotosCodec;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    private async Task SendRecognitionAsync(PhotoRecognitionTask task, CancellationToken token)
    {
        if (task.Record.Similar is not null) { await SendSimilarAsync(task, token).ConfigureAwait(false); return; }
        if (task.Record.Manual is not null) { await SendManualFacesAsync(task, token).ConfigureAwait(false); return; }
        var sent = false;
        try
        {
            var record = task.Record; var generation = Volatile.Read(ref _accessGeneration);
            _ = await PrepareRecognitionCoreAsync(record, true, token).ConfigureAwait(false);
            if (record.Kind == SynologyPhotoRecognitionKind.RenamePerson && record.People[0].NameHash == record.NameHash)
            {
                task.Record = record with { State = SynologyPhotoChangeState.Completed, Accepted = true, CompletedIds = [record.People[0].Id] };
                task.Name = null; await SaveRecognitionAsync(task).ConfigureAwait(false); return;
            }
            var fields = record.Kind switch
            {
                SynologyPhotoRecognitionKind.RenamePerson => Parameters(("id", record.People[0].Id), ("name", task.Name!)),
                SynologyPhotoRecognitionKind.MergePeople => Parameters(("target_id", record.People[0].Id), ("merged_id", record.People.Skip(1).Select(person => person.Id).ToArray()), ("name", task.Name!)),
                SynologyPhotoRecognitionKind.ShowPeople => Parameters(("id", record.People.Select(person => person.Id).ToArray()), ("show", record.Visible)),
                SynologyPhotoRecognitionKind.RemovePersonFaces => Parameters(("person_id", record.People[0].Id), ("face_id", record.Faces!.Select(face => face.Id).ToArray())),
                SynologyPhotoRecognitionKind.ReassignPersonFaces => Parameters(("target_id", record.People.Length == 2 ? record.People[1].Id : 0), ("name", task.Name!), ("face_id", record.Faces!.Select(face => face.Id).ToArray())),
                SynologyPhotoRecognitionKind.SetPersonCover => Parameters(("id", record.People[0].Id), ("photo_id", record.Photos[0].Id)),
                SynologyPhotoRecognitionKind.ShowConcepts => Parameters(("id", record.Concepts!.Select(value => value.Id).ToArray()), ("visibility", record.Visible)),
                SynologyPhotoRecognitionKind.SetConceptCover => Parameters(("id", record.Concepts![0].Id), ("photo_id", record.Photos[0].Id)),
                SynologyPhotoRecognitionKind.RemoveConceptPhotos => Parameters(("id", record.Concepts![0].Id), ("item_id", record.Photos.Select(photo => photo.Id).ToArray())),
                _ => throw Invalid(),
            };
            task.Record = record with { State = SynologyPhotoChangeState.Submitting, Accepted = false, Failure = null };
            await SaveRecognitionAsync(task).ConfigureAwait(false); RequireGeneration(generation, token); CheckRecognitionOwner(record);
            _ = await PrepareRecognitionCoreAsync(record, true, token).ConfigureAwait(false);
            RequireGeneration(generation, token); sent = true;
            var version = record.Kind is SynologyPhotoRecognitionKind.MergePeople or SynologyPhotoRecognitionKind.ShowConcepts ? 2 : 1;
            var method = record.Kind switch { SynologyPhotoRecognitionKind.RenamePerson => "set", SynologyPhotoRecognitionKind.MergePeople => "merge", SynologyPhotoRecognitionKind.ShowPeople => "show",
                SynologyPhotoRecognitionKind.RemovePersonFaces => "delete_face", SynologyPhotoRecognitionKind.ReassignPersonFaces => "separate", SynologyPhotoRecognitionKind.SetPersonCover or SynologyPhotoRecognitionKind.SetConceptCover => "set_cover",
                SynologyPhotoRecognitionKind.ShowConcepts => "set_visibility", SynologyPhotoRecognitionKind.RemoveConceptPhotos => "hide_item", _ => throw Invalid() };
            var receipt = await _api.WritePhotoAsync(_profile, _session, Capability(ConceptKind(record.Kind) ? "Browse.Concept" : "Browse.Person", version, record.Space), version, method, fields, token).ConfigureAwait(false);
            var accepted = receipt.Status == SynologyPhotoWriteStatus.Accepted;
            if (accepted && record.Kind == SynologyPhotoRecognitionKind.RenamePerson)
                accepted = receipt.Data is { } data && Positive(data, "id") == record.People[0].Id && PhotoTextHash(Text(data, "name")) == record.NameHash;
            long? coverReceipt = null, personReceipt = null;
            if (accepted && record.Kind == SynologyPhotoRecognitionKind.SetPersonCover)
            {
                accepted = receipt.Data is { } data && Positive(data, "id") == record.People[0].Id && Positive(data, "cover") > 0;
                if (accepted) coverReceipt = Positive(receipt.Data!, "cover");
            }
            if (accepted && record.Kind == SynologyPhotoRecognitionKind.ReassignPersonFaces)
            {
                accepted = receipt.Data is { } data && Positive(data, "id") != record.People[0].Id && PhotoTextHash(Text(data, "name")) == record.NameHash &&
                    (record.People.Length == 1 || Positive(data, "id") == record.People[1].Id);
                if (accepted) personReceipt = Positive(receipt.Data!, "id");
            }
            task.Record = task.Record with { State = receipt.Status == SynologyPhotoWriteStatus.Rejected ? SynologyPhotoChangeState.Failed : SynologyPhotoChangeState.PendingReview,
                Accepted = accepted, Failure = receipt.Failure, CoverReceipt = coverReceipt, PersonReceipt = personReceipt };
            await SaveRecognitionAsync(task).ConfigureAwait(false); RequireGeneration(generation, token); CheckRecognitionOwner(record);
            await ReviewRecognitionCoreAsync(task, token).ConfigureAwait(false);
        }
        catch (Exception error) when (ManagementError(error))
        {
            RequireManagementStore(); task.Record = task.Record with { State = sent ? SynologyPhotoChangeState.PendingReview : SynologyPhotoChangeState.Failed, Failure = UploadFailure(error) };
            await SaveRecognitionAsync(task).ConfigureAwait(false);
        }
    }
    private async Task ReviewRecognitionCoreAsync(PhotoRecognitionTask task, CancellationToken token)
    {
        var record = task.Record; CheckRecognitionOwner(record);
        if (record.Similar is not null) { await ReviewSimilarAsync(task, token).ConfigureAwait(false); return; }
        if (record.State is not (SynologyPhotoChangeState.Submitting or SynologyPhotoChangeState.PendingReview)) return;
        if (record.Manual is not null) { await ReviewManualFacesAsync(task, token).ConfigureAwait(false); return; }
        if (ConceptKind(record.Kind)) { await ReviewConceptAsync(task, token).ConfigureAwait(false); return; }
        try
        {
            var generation = Volatile.Read(ref _accessGeneration); await FreshPeopleAccessAsync(record.Space, token).ConfigureAwait(false);
            if (RecognitionUsesPhotos(record.Kind)) { await ReviewPersonFacesAsync(task, generation, token).ConfigureAwait(false); return; }
            IReadOnlyList<SynologyPhotoPerson> matching; long[] completed; long[] removed = [];
            if (record.Kind == SynologyPhotoRecognitionKind.ShowPeople)
            {
                var people = await PersonStatesAsync(record.People.Select(person => person.Id).ToArray(), record.Space, token).ConfigureAwait(false);
                matching = people.Where(person => person.Visible == record.Visible).ToArray(); completed = matching.Select(person => person.Person.Id).ToArray();
            }
            else
            {
                var people = await PeopleAsync(record.Space, false, token).ConfigureAwait(false);
                var target = people.SingleOrDefault(person => person.Person.Id == record.People[0].Id);
                if (record.Kind == SynologyPhotoRecognitionKind.RenamePerson)
                {
                    if (target is not null && PhotoTextHash(target.Person.Name) == record.NameHash) matching = [target];
                    else if (target is null && record.NameHash == PhotoTextHash("") && record.People[0].Count is < 2)
                    { matching = []; removed = [record.People[0].Id]; }
                    else return;
                }
                else
                {
                    if (target is null || PhotoTextHash(target.Person.Name) != record.NameHash || people.Any(person => record.People.Skip(1).Any(original => original.Id == person.Person.Id))) return;
                    var photos = await CategoryPhotosAsync(SynologyPhotoCategory.People, target.Person.Id, record.Space, token).ConfigureAwait(false);
                    if (!photos.Select(photo => photo.Id.ItemId).ToHashSet().SetEquals(record.Photos.Select(photo => photo.Id)) ||
                        photos.Any(photo => !record.Photos.Any(original => original.Id == photo.Id.ItemId && original.IdentityHash == RecognitionPhotoHash(photo)))) return;
                    matching = [target]; removed = record.People.Skip(1).Select(person => person.Id).ToArray();
                }
                completed = record.People.Select(person => person.Id).ToArray();
            }
            RequireGeneration(generation, token); CheckRecognitionOwner(record);
            // 他端达到同一状态不能替代本次回执；部分显示结果保留已完成事实，未知余项不重放。
            if (!record.Accepted) return;
            task.People = matching;
            var confirmed = (record.CompletedIds ?? []).Concat(completed).Distinct().ToArray();
            task.Record = record with { State = completed.Length == record.People.Length ? SynologyPhotoChangeState.Completed : SynologyPhotoChangeState.PendingReview,
                CompletedIds = confirmed, RemovedIds = removed, Failure = null };
            if (task.Record.State == SynologyPhotoChangeState.Completed) task.Name = null;
            await SaveRecognitionAsync(task).ConfigureAwait(false);
        }
        catch (Exception error) when (ManagementError(error)) { RequireManagementStore(); }
    }
    private async Task ReviewPersonFacesAsync(PhotoRecognitionTask task, long generation, CancellationToken token)
    {
        var record = task.Record; if (!record.Accepted) return;
        var photos = await RecognitionOriginalsAsync(record, token).ConfigureAwait(false);
        long[] removedPhotos = [];
        if (record.Kind == SynologyPhotoRecognitionKind.SetPersonCover)
        {
            if (record.CoverReceipt is null) return;
            var detail = await PersonDetailsAsync(record.People[0].Id, record.Space, token).ConfigureAwait(false);
            if (Positive(detail, "cover") != record.CoverReceipt) return;
        }
        else
        {
            var current = await PersonFacesAsync(record.People[0].Id, photos, token).ConfigureAwait(false);
            if (current.Any(face => record.Faces!.Any(original => original.Id == face.Id))) return;
            if (record.Kind == SynologyPhotoRecognitionKind.ReassignPersonFaces)
            {
                if (record.PersonReceipt is not { } target) return;
                var destination = await PersonFacesAsync(target, photos, token).ConfigureAwait(false);
                if (record.Faces!.Any(face => !destination.Any(item => item.Id == face.Id && item.Photo.Id.ItemId == face.PhotoId))) return;
                var detail = await PersonDetailsAsync(target, record.Space, token).ConfigureAwait(false);
                if (PhotoTextHash(Text(detail, "name")) != record.NameHash) return;
            }
            removedPhotos = record.Photos.Where(photo => !current.Any(face => face.Photo.Id.ItemId == photo.Id)).Select(photo => photo.Id).ToArray();
        }
        var people = await PeopleAsync(record.Space, false, token).ConfigureAwait(false);
        if (record.Kind == SynologyPhotoRecognitionKind.SetPersonCover && !people.Any(person => person.Person.Id == record.People[0].Id)) return;
        RequireGeneration(generation, token); CheckRecognitionOwner(record);
        task.People = people.Where(person => RecognitionPersonIds(record).Contains(person.Person.Id)).ToArray();
        task.Record = record with { State = SynologyPhotoChangeState.Completed, CompletedIds = RecognitionCompletionIds(record), Failure = null,
            RemovedIds = people.Any(person => person.Person.Id == record.People[0].Id) ? [] : [record.People[0].Id], RemovedPhotoIds = removedPhotos };
        task.Name = null; await SaveRecognitionAsync(task).ConfigureAwait(false);
    }
}
