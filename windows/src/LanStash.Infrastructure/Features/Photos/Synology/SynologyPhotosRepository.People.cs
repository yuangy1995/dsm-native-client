using System.Collections.Concurrent;
using System.Text.Json.Nodes;
using LanStash.Domain;
using static LanStash.Infrastructure.SynologyPhotosCodec;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    private readonly ConcurrentDictionary<(SynologyPhotoSpace, SynologyPhotoCategory, long), SynologyPhotoThumbnail> _categoryThumbnails = new();
    public bool SupportsRecognitionManagement => SupportsManagement;
    private SynologyPhotoPerson Person(JsonObject raw, SynologyPhotoSpace space)
    {
        var id = Positive(raw, "id"); var count = OptionalInt(raw, "item_count");
        if (count < 0) throw Invalid();
        var thumb = OptionalObject(OptionalObject(raw, "additional") ?? new(), "thumbnail");
        SynologyPhotoThumbnail? thumbnail = thumb is null ? null : new(thumb["unit_id"] is null ? id : Positive(thumb, "unit_id"), Text(thumb, "cache_key"))
        { Space = space, Type = thumb["unit_id"] is null ? SynologyPhotoThumbnailType.Person : SynologyPhotoThumbnailType.Unit, NativeSize = true };
        return new(new(id, Text(raw, "name"), Count: count) { Space = space, Thumbnail = thumbnail }, raw["show"] is null ? null : Boolean(raw, "show"));
    }
    private void CachePeople(IReadOnlyList<SynologyPhotoPerson> people, SynologyPhotoSpace space, bool replace)
    {
        if (replace) foreach (var key in _categoryThumbnails.Keys.Where(key => key.Item1 == space && key.Item2 == SynologyPhotoCategory.People)) _categoryThumbnails.TryRemove(key, out _);
        foreach (var person in people)
        {
            var key = (space, SynologyPhotoCategory.People, person.Person.Id);
            if (person.Person.Thumbnail is { } thumbnail) _categoryThumbnails[key] = thumbnail;
            else _categoryThumbnails.TryRemove(key, out _);
        }
    }
    private async Task<SynologyPhotoPerson[]> PersonPageAsync(SynologyPhotoSpace space, int offset, int limit, bool hidden, CancellationToken token)
    {
        RequireCategoryAccess(SynologyPhotoCategory.People, space); var generation = Volatile.Read(ref _accessGeneration);
        var fields = PageParameters(offset, limit); Add(fields, Parameters(("additional", new[] { "thumbnail" })));
        if (hidden) Add(fields, Parameters(("show_more", true), ("show_hidden", true)));
        var people = List(await ReadAsync("Browse.Person", 1, "list", fields, token, space).ConfigureAwait(false)).Select(raw => Person(raw, space)).ToArray();
        if (people.Length > limit || people.DistinctBy(item => item.Person.Id).Count() != people.Length || hidden && people.Any(item => item.Visible is null)) throw Invalid();
        lock (_accessGate) { RequireGeneration(generation, token); CachePeople(people, space, offset == 0); }
        return people;
    }
    public async Task<IReadOnlyList<SynologyPhotoPerson>> PeopleAsync(SynologyPhotoSpace space, bool includeHidden, CancellationToken cancellationToken = default)
    {
        var generation = Volatile.Read(ref _accessGeneration); var people = new List<SynologyPhotoPerson>(); var seen = new HashSet<long>();
        while (true)
        {
            var page = await PersonPageAsync(space, people.Count, 500, includeHidden, cancellationToken).ConfigureAwait(false);
            RequireGeneration(generation, cancellationToken);
            foreach (var person in page) { if (!seen.Add(person.Person.Id)) throw Invalid(); people.Add(person); }
            if (page.Length < 500) return people;
        }
    }
    private async Task<SynologyPhotoPerson[]> PersonStatesAsync(long[] ids, SynologyPhotoSpace space, CancellationToken token)
    {
        RequireCategoryAccess(SynologyPhotoCategory.People, space); var generation = Volatile.Read(ref _accessGeneration);
        var people = List(await ReadAsync("Browse.Person", 1, "get", Parameters(("id", ids), ("additional", new[] { "thumbnail" })), token, space).ConfigureAwait(false))
            .Select(raw => Person(raw, space)).ToArray();
        if (people.Length != ids.Length || people.Select(person => person.Person.Id).Distinct().Count() != ids.Length ||
            !people.Select(person => person.Person.Id).ToHashSet().SetEquals(ids) || people.Any(person => person.Visible is null)) throw Invalid();
        lock (_accessGate) { RequireGeneration(generation, token); CachePeople(people, space, false); }
        return people;
    }
    public async Task<byte[]> CategoryImageAsync(SynologyPhotoCategory category, SynologyPhotoCollection item, CancellationToken cancellationToken = default)
    {
        RequireCategoryAccess(category, item.Space); var generation = Volatile.Read(ref _accessGeneration);
        if (item.Thumbnail is not { } thumbnail || !_categoryThumbnails.TryGetValue((item.Space, category, item.Id), out var known) || known != thumbnail)
            throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        var bytes = await _api.ReadPhotoThumbnailAsync(_profile, _session, thumbnail, false, cancellationToken).ConfigureAwait(false);
        RequireGeneration(generation, cancellationToken); return bytes;
    }
    private Task FreshPeopleAccessAsync(SynologyPhotoSpace space, CancellationToken token) => FreshRecognitionAccessAsync(SynologyPhotoCategory.People, space, token);
    private async Task FreshRecognitionAccessAsync(SynologyPhotoCategory category, SynologyPhotoSpace space, CancellationToken token)
    {
        RequireCategoryAccess(category, space); var key = category == SynologyPhotoCategory.Subjects ? "enable_concept" : "enable_person";
        var info = await ReadAsync("UserInfo", 1, "me", cancellationToken: token, space: null).ConfigureAwait(false);
        if (!Boolean(info, "enabled") || Positive(info, "id") != _currentUserId) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        var user = await ReadAsync("Setting.User", 1, "get", cancellationToken: token, space: null).ConfigureAwait(false);
        var admin = await ReadAsync("Setting.Admin", 1, "get", cancellationToken: token, space: null).ConfigureAwait(false);
        if (admin[key] is not null && !Boolean(admin, key)) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        if (space == SynologyPhotoSpace.Personal)
        {
            if (!Boolean(user, "enable_home_service") || user[key] is not null && !Boolean(user, key))
                throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        }
        else
        {
            var team = await ReadAsync("Setting.TeamSpace", 1, "get", cancellationToken: token, space: null).ConfigureAwait(false);
            if (!Boolean(team, "enabled") || !Permission(team, key) || Text(user, "team_space_permission") != "management")
                throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        }
    }
    private async Task<SynologyPhoto[]> CategoryPhotosAsync(SynologyPhotoCategory category, long id, SynologyPhotoSpace space, CancellationToken token)
    {
        var generation = Volatile.Read(ref _accessGeneration); var query = new SynologyPhotoQuery.Category(category, id, 0, 0) { Space = space };
        var days = await TimelineAsync(query, token).ConfigureAwait(false); if (days.Count == 0) return [];
        var start = new DateTimeOffset(days.Min(day => day.Date).ToDateTime(TimeOnly.MinValue), TimeSpan.Zero).ToUnixTimeSeconds();
        var end = new DateTimeOffset(days.Max(day => day.Date).ToDateTime(TimeOnly.MinValue), TimeSpan.Zero).ToUnixTimeSeconds();
        query = query with { Start = Math.Max(0, start - 86400), End = end + 172800 };
        var photos = new List<SynologyPhoto>(); var seen = new HashSet<SynologyPhotoIdentity>(); var offset = 0;
        while (true)
        {
            var page = await PhotosAsync(query, offset, 500, token).ConfigureAwait(false); RequireGeneration(generation, token);
            foreach (var photo in page.Items) { if (!seen.Add(photo.Id)) throw Invalid(); photos.Add(photo); }
            if (!page.HasMore) return photos.ToArray(); offset = page.NextOffset;
        }
    }
}
