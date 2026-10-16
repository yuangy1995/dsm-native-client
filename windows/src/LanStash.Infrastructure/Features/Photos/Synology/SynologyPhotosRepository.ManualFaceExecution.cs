using System.Text.Json.Nodes;
using LanStash.Domain;
using static LanStash.Infrastructure.SynologyPhotosCodec;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    private static ManualFaceRecord WithManualChange(ManualFaceRecord manual, int index, Func<ManualChange, ManualChange> update)
    {
        var changes = manual.Changes.ToArray(); changes[index] = update(changes[index]); return manual with { Changes = changes };
    }
    private static PhotoRecognitionRecord ManualResult(PhotoRecognitionRecord record, SynologyPhotoFailure? failure = null)
    {
        var manual = record.Manual!; var done = manual.Changes.All(change => change.State == ManualFaceStep.Completed);
        return record with { State = done ? SynologyPhotoChangeState.Completed : ManualHasPending(manual) ? SynologyPhotoChangeState.PendingReview : SynologyPhotoChangeState.Failed,
            Accepted = manual.Add == ManualFaceStep.Accepted || manual.Changes.Any(change => change.State is ManualFaceStep.Accepted or ManualFaceStep.Completed),
            Failure = done ? null : failure ?? record.Failure };
    }
    private static SynologyPhotoFaceChange ManualInput(PhotoRecognitionTask task, ManualChange change)
    {
        var input = task.ManualInput?.SingleOrDefault(input => input.Id == change.Id);
        if (input is null || input.Kind != change.Kind || input.Person?.Id != change.PersonId ||
            (input.Name is null ? null : PhotoTextHash(input.Name)) != change.NameHash ||
            change.Kind == SynologyPhotoFaceChangeKind.Add && (input.Jpeg is null || FaceImageHash(input.Jpeg) != change.ImageHash || input.Bounds != change.Bounds)) throw Invalid();
        return input;
    }
    private static JsonObject ManualAddParameters(ManualChange change, SynologyPhotoFaceChange input)
    {
        var box = change.Bounds!;
        var value = new JsonObject { ["face_id_temp"] = change.TemporaryId, ["face_bounding_box"] = new JsonObject
        { ["top_left"] = new JsonObject { ["x"] = box.X, ["y"] = box.Y }, ["bottom_right"] = new JsonObject { ["x"] = box.X + box.Width, ["y"] = box.Y + box.Height } } };
        if (change.PersonId is { } person) value["person_id"] = person; else value["name"] = input.Name;
        return value;
    }
    private static ManualFaceStep ReceiptStep(SynologyPhotoWriteReceipt receipt) => receipt.Status switch
    { SynologyPhotoWriteStatus.Accepted => ManualFaceStep.Accepted, SynologyPhotoWriteStatus.Rejected => ManualFaceStep.Rejected, _ => ManualFaceStep.Submitting };
    private async Task<bool> SendManualStepAsync(PhotoRecognitionTask task, Func<ManualFaceRecord, ManualFaceRecord> submitting,
        Func<CancellationToken, Task<SynologyPhotoWriteReceipt>> send, Func<ManualFaceRecord, SynologyPhotoWriteReceipt, ManualFaceRecord> accepted, CancellationToken token)
    {
        var original = task.Record; var generation = Volatile.Read(ref _accessGeneration); var sent = false;
        try
        {
            _ = await PrepareManualFacesAsync(original, token).ConfigureAwait(false);
            task.Record = original with { Manual = submitting(original.Manual!), State = SynologyPhotoChangeState.Submitting, Failure = null };
            await SaveRecognitionAsync(task).ConfigureAwait(false);
            // 检查落盘期间发生的权限或对象变化；发送前失败可以恢复未发送阶段。
            _ = await PrepareManualFacesAsync(original, token).ConfigureAwait(false); RequireGeneration(generation, token); CheckRecognitionOwner(original);
            sent = true; var receipt = await send(token).ConfigureAwait(false);
            task.Record = ManualResult(task.Record with { Manual = accepted(task.Record.Manual!, receipt) }, receipt.Failure);
            await SaveRecognitionAsync(task).ConfigureAwait(false); RequireGeneration(generation, token); CheckRecognitionOwner(original);
            return receipt.Status == SynologyPhotoWriteStatus.Accepted;
        }
        catch (Exception error) when (ManagementError(error))
        {
            RequireManagementStore(); if (!sent) task.Record = original;
            task.Record = ManualResult(task.Record, UploadFailure(error)); await SaveRecognitionAsync(task).ConfigureAwait(false); return false;
        }
    }
    private async Task SendManualFacesAsync(PhotoRecognitionTask task, CancellationToken token)
    {
        try
        {
            _ = await PrepareManualFacesAsync(task.Record, token).ConfigureAwait(false);
            var additions = task.Record.Manual!.Changes.Where(change => change.Kind == SynologyPhotoFaceChangeKind.Add).ToArray();
            if (additions.Length > 0 && task.Record.Manual.Add is ManualFaceStep.Ready or ManualFaceStep.Rejected)
            {
                var fields = Parameters(("id_item", task.Record.Photos[0].Id), ("face", additions.Select(change => ManualAddParameters(change, ManualInput(task, change))).ToArray()));
                if (!await SendManualStepAsync(task, manual => manual with { Add = ManualFaceStep.Submitting },
                    ct => _api.WritePhotoAsync(_profile, _session, Capability("Browse.Person", 3, task.Record.Space), 3, "add_face", fields, ct),
                    (manual, receipt) =>
                    {
                        if (receipt.Status != SynologyPhotoWriteStatus.Accepted) return manual with { Add = ReceiptStep(receipt) };
                        var entries = List(receipt.Data ?? throw Invalid()).Select(raw => (Id: Positive(raw, "face_id"), Temp: Text(raw, "face_id_temp"))).ToArray();
                        if (entries.Any(entry => manual.Originals.Any(original => original.Id == entry.Id) || !additions.Any(change => change.TemporaryId == entry.Temp)) ||
                            entries.DistinctBy(entry => entry.Id).Count() != entries.Length || entries.DistinctBy(entry => entry.Temp).Count() != entries.Length) throw Invalid();
                        return manual with { Add = ManualFaceStep.Accepted, Changes = manual.Changes.Select(change => change.Kind == SynologyPhotoFaceChangeKind.Add
                            ? change with { FaceReceipt = entries.Where(entry => entry.Temp == change.TemporaryId).Select(entry => (long?)entry.Id).SingleOrDefault() } : change).ToArray() };
                    }, token).ConfigureAwait(false)) return;
            }
            for (var index = 0; index < task.Record.Manual!.Changes.Length; index++)
            {
                var change = task.Record.Manual.Changes[index];
                if (change.Kind != SynologyPhotoFaceChangeKind.Add || change.FaceReceipt is null || change.State == ManualFaceStep.Completed) continue;
                if (change.Upload is not (ManualFaceStep.Ready or ManualFaceStep.Rejected)) return;
                var input = ManualInput(task, change); var position = index;
                if (!await SendManualStepAsync(task, manual => WithManualChange(manual, position, item => item with { Upload = ManualFaceStep.Submitting }),
                    ct => _api.UploadPhotoFaceAsync(_profile, _session, Capability("Upload.Face", 1, task.Record.Space), change.FaceReceipt.Value, input.Jpeg!, ct),
                    (manual, receipt) => WithManualChange(manual, position, item => item with { Upload = ReceiptStep(receipt) }), token).ConfigureAwait(false)) return;
                await ReviewManualFacesAsync(task, token).ConfigureAwait(false);
                if (task.Record.Manual.Changes[index].State != ManualFaceStep.Completed) return;
            }
            // 缺少部分新增回执时只保存明确编号的裁剪图；旧框保持原样，避免丢失原有识别资料。
            if (task.Record.Manual!.Changes.Any(change => change.Kind == SynologyPhotoFaceChangeKind.Add && change.State != ManualFaceStep.Completed))
            { task.Record = ManualResult(task.Record, SynologyPhotoFailure.WriteFailed); await SaveRecognitionAsync(task).ConfigureAwait(false); return; }
            for (var index = 0; index < task.Record.Manual.Changes.Length; index++)
            {
                var change = task.Record.Manual.Changes[index]; if (change.Kind == SynologyPhotoFaceChangeKind.Add || change.State == ManualFaceStep.Completed) continue;
                if (change.State is not (ManualFaceStep.Ready or ManualFaceStep.Rejected)) return;
                var fields = Parameters(("face_id", new[] { change.Original!.Id })); var remove = change.Kind == SynologyPhotoFaceChangeKind.Remove;
                if (remove) Add(fields, Parameters(("person_id", change.Original.PersonId)));
                else
                {
                    Add(fields, Parameters(("name", ManualInput(task, change).Name!)));
                    if (change.PersonId is { } person) Add(fields, Parameters(("target_id", person)));
                }
                var position = index;
                if (!await SendManualStepAsync(task, manual => WithManualChange(manual, position, item => item with { State = ManualFaceStep.Submitting }),
                    ct => _api.WritePhotoAsync(_profile, _session, Capability("Browse.Person", 1, task.Record.Space), 1, remove ? "delete_face" : "separate", fields, ct),
                    (manual, receipt) =>
                    {
                        long? person = null;
                        if (!remove && receipt.Status == SynologyPhotoWriteStatus.Accepted)
                        {
                            var data = receipt.Data ?? throw Invalid(); person = Positive(data, "id");
                            if (PhotoTextHash(Text(data, "name")) != change.NameHash || change.PersonId is { } target && target != person) throw Invalid();
                        }
                        return WithManualChange(manual, position, item => item with { State = ReceiptStep(receipt), PersonReceipt = person });
                    }, token).ConfigureAwait(false)) return;
                await ReviewManualFacesAsync(task, token).ConfigureAwait(false);
                if (task.Record.Manual.Changes[index].State != ManualFaceStep.Completed) return;
            }
            task.Record = ManualResult(task.Record); if (!ActiveRecognition(task.Record)) task.ManualInput = null;
            await SaveRecognitionAsync(task).ConfigureAwait(false);
        }
        catch (Exception error) when (ManagementError(error))
        {
            RequireManagementStore(); task.Record = ManualResult(task.Record, UploadFailure(error)); await SaveRecognitionAsync(task).ConfigureAwait(false);
        }
    }
    private static bool MatchesManualAddition(ManualChange change, SynologyPhotoFaceRegion face) => face.Id == change.FaceReceipt && face.PersonId > 0 &&
        PhotoTextHash(face.Name) == change.NameHash && change.Bounds!.Matches(face.Bounds) && (change.PersonId is null || change.PersonId == face.PersonId);
    private async Task ReviewManualFacesAsync(PhotoRecognitionTask task, CancellationToken token)
    {
        var record = task.Record; CheckRecognitionOwner(record);
        try
        {
            var generation = Volatile.Read(ref _accessGeneration); await FreshPeopleAccessAsync(record.Space, token).ConfigureAwait(false);
            var photo = (await RecognitionOriginalsAsync(record, token).ConfigureAwait(false)).Single();
            await AuthorizePhotoEditAsync(photo, token).ConfigureAwait(false);
            var faces = await PhotoFacesAsync(photo, token).ConfigureAwait(false); var manual = record.Manual!; var changes = manual.Changes.ToArray();
            for (var index = 0; index < changes.Length; index++)
            {
                var change = changes[index]; if (change.State == ManualFaceStep.Completed) continue;
                if (change.Kind == SynologyPhotoFaceChangeKind.Add)
                {
                    if (change.FaceReceipt is not { } id || change.Upload is not (ManualFaceStep.Accepted or ManualFaceStep.Submitting) ||
                        faces.SingleOrDefault(face => face.Id == id) is not { Thumbnail: not null } face || !MatchesManualAddition(change, face)) continue;
                    if (change.Upload == ManualFaceStep.Submitting)
                    {
                        var image = await FaceImageAsync(new(face.Id, face.PersonId, photo, face.Thumbnail), token).ConfigureAwait(false);
                        if (FaceImageHash(image) != change.ImageHash) continue;
                    }
                    changes[index] = change with { State = ManualFaceStep.Completed, Upload = ManualFaceStep.Completed, PersonReceipt = face.PersonId };
                }
                else if (change.State == ManualFaceStep.Accepted)
                {
                    var face = faces.SingleOrDefault(face => face.Id == change.Original!.Id);
                    if (change.Kind == SynologyPhotoFaceChangeKind.Remove ? face is null : face is not null && face.PersonId == change.PersonReceipt &&
                        PhotoTextHash(face.Name) == change.NameHash && change.Original!.Bounds.Matches(face.Bounds)) changes[index] = change with { State = ManualFaceStep.Completed };
                }
            }
            RequireGeneration(generation, token); CheckRecognitionOwner(record);
            task.Record = ManualResult(record with { Manual = manual with { Changes = changes } });
            if (!ActiveRecognition(task.Record)) task.ManualInput = null;
            await SaveRecognitionAsync(task).ConfigureAwait(false);
        }
        catch (Exception error) when (ManagementError(error)) { RequireManagementStore(); }
    }
}
