using System.Reflection;
using LanStash.App.Features.Containers;
using LanStash.Domain;

namespace LanStash.Tests.Containers;

public sealed class ContainerRegistryViewModelTests
{
    private static ContainerRegistryImage Image(string name) => new(name, "registry.invalid", "Synthetic image", 10, true, null, null);
    private static (Fake Fake, ContainerRegistryViewModel Model) Ready()
    {
        var repository = DispatchProxy.Create<IContainerManagerRepository, Fake>(); var fake = (Fake)repository;
        var model = new ContainerRegistryViewModel(); model.Activate(repository); model.SetQuery("synthetic"); return (fake, model);
    }
    [Fact]
    public async Task SearchSelectFilterAndReloadFormReadOnlyWorkflow()
    {
        var (fake, model) = Ready(); using var owned = model;
        await model.SearchAsync(); Assert.True(model.HasSearched); Assert.Equal(2, model.Results.Count);
        await model.SelectImageAsync(model.Results[0]); Assert.Equal(new[] { "latest", "v1" }, model.Tags); Assert.Equal("synthetic/a", fake.LastRepository);
        model.SelectTag("v1"); Assert.Equal("v1", model.SelectedTag); model.SetTagFilter("missing");
        Assert.True(model.IsTagFilterEmpty); Assert.Null(model.SelectedTag); Assert.Empty(model.Tags);
        model.SetTagFilter(""); await model.ReloadTagsAsync(); Assert.False(model.IsTagFilterEmpty); Assert.Equal(2, model.Tags.Count);
        Assert.Equal(1, fake.Searches); Assert.Equal(2, fake.TagReads);
    }
    [Fact]
    public async Task QueryChangeCancelsAndDiscardsOldSearchEvenWhenTransportIgnoresCancellation()
    {
        var (fake, model) = Ready(); using var owned = model;
        var old = new TaskCompletionSource<IReadOnlyList<ContainerRegistryImage>>(TaskCreationOptions.RunContinuationsAsynchronously);
        fake.Search = _ => old.Task; var first = model.SearchAsync(); var token = fake.SearchToken;
        model.SetQuery("new-query"); Assert.True(token.IsCancellationRequested); Assert.False(model.IsSearching);
        fake.Search = _ => Task.FromResult<IReadOnlyList<ContainerRegistryImage>>([Image("new-image")]); await model.SearchAsync();
        old.SetResult([Image("stale-image")]); await first;
        Assert.Equal("new-image", Assert.Single(model.Results).Name); Assert.False(model.IsSearching);
    }
    [Fact]
    public async Task SwitchingImageKeepsLateTagsAndErrorsOutOfNewSelection()
    {
        var (fake, model) = Ready(); using var owned = model; await model.SearchAsync();
        var old = new TaskCompletionSource<IReadOnlyList<string>>(TaskCreationOptions.RunContinuationsAsynchronously);
        fake.Tags = name => name.EndsWith("/a", StringComparison.Ordinal) ? old.Task : Task.FromResult<IReadOnlyList<string>>(["b-tag"]);
        var first = model.SelectImageAsync(model.Results[0]); var token = fake.TagsToken;
        await model.SelectImageAsync(model.Results[1]); Assert.True(token.IsCancellationRequested);
        old.SetException(new IOException("合成旧请求失败")); await first;
        Assert.Equal("synthetic/b", model.SelectedImage!.Name); Assert.Equal("b-tag", Assert.Single(model.Tags)); Assert.Null(model.TagsError);
    }
    [Fact]
    public async Task StartingNewSearchClearsSelectionFilterAndTags()
    {
        var (fake, model) = Ready(); using var owned = model; await model.SearchAsync(); await model.SelectImageAsync(model.Results[0]);
        model.SetTagFilter("v"); model.SelectTag("v1"); await model.SearchAsync();
        Assert.Null(model.SelectedImage); Assert.Null(model.SelectedTag); Assert.Equal("", model.TagFilter); Assert.Empty(model.Tags); Assert.Equal(2, fake.Searches);
    }
    [Fact]
    public async Task MissingCapabilityInvalidInputAndForeignSelectionCannotRequest()
    {
        var (fake, model) = Ready(); using var owned = model; fake.Available = false; await model.SearchAsync(); Assert.Equal(0, fake.Searches);
        fake.Available = true; model.SetQuery(new string('x', 201)); Assert.NotNull(model.QueryError); await model.SearchAsync(); Assert.Equal(0, fake.Searches);
        model.SetQuery("valid"); await model.SearchAsync(); await model.SelectImageAsync(new(Image("foreign"))); Assert.Equal(0, fake.TagReads);
        model.SelectTag("not-loaded"); Assert.Null(model.SelectedTag);
    }
    [Fact]
    public async Task FailedSearchIsNotEmptyAndRetryCanRecover()
    {
        var (fake, model) = Ready(); using var owned = model; fake.Search = _ => Task.FromException<IReadOnlyList<ContainerRegistryImage>>(new IOException("合成读取失败"));
        await model.SearchAsync(); Assert.NotNull(model.SearchError); Assert.True(model.HasSearched); Assert.Empty(model.Results);
        fake.Search = _ => Task.FromResult<IReadOnlyList<ContainerRegistryImage>>([]); await model.SearchAsync(); Assert.Null(model.SearchError); Assert.True(model.HasSearched); Assert.Empty(model.Results);
    }
    [Fact]
    public async Task FailedTagsAreNotEmptyAndRetryClearsPriorError()
    {
        var (fake, model) = Ready(); using var owned = model; await model.SearchAsync(); fake.Tags = _ => Task.FromException<IReadOnlyList<string>>(new IOException("合成读取失败"));
        await model.SelectImageAsync(model.Results[0]); Assert.NotNull(model.TagsError); Assert.False(model.HasLoadedTags);
        fake.Tags = _ => Task.FromResult<IReadOnlyList<string>>([]); await model.ReloadTagsAsync(); Assert.Null(model.TagsError); Assert.True(model.HasLoadedTags); Assert.Empty(model.Tags);
    }
    [Fact]
    public async Task ExpiredSessionBlocksFurtherRequestsUntilReactivation()
    {
        var (fake, model) = Ready(); using var owned = model;
        fake.Search = _ => Task.FromException<IReadOnlyList<ContainerRegistryImage>>(new DsmException("synthetic", "synthetic", 106, authenticationFailure: true));
        await model.SearchAsync(); Assert.True(model.RequiresReconnect); Assert.False(model.CanSearch);
        model.SetQuery("another"); await model.SearchAsync(); Assert.Equal(1, fake.Searches);
    }
    [Fact]
    public async Task ProfileChangeAndDisposeCancelWithoutAcceptingLateResults()
    {
        var (fake, model) = Ready();
        var old = new TaskCompletionSource<IReadOnlyList<ContainerRegistryImage>>(TaskCreationOptions.RunContinuationsAsynchronously); fake.Search = _ => old.Task;
        var searching = model.SearchAsync(); model.Activate(DispatchProxy.Create<IContainerManagerRepository, Fake>()); Assert.True(fake.SearchToken.IsCancellationRequested);
        old.SetResult([Image("old-profile")]); await searching; Assert.Empty(model.Results); Assert.False(model.HasSearched);
        model.Dispose(); Assert.False(model.IsAvailable);
    }
    public class Fake : DispatchProxy
    {
        public bool Available { get; set; } = true;
        public int Searches { get; private set; } public int TagReads { get; private set; }
        public string? LastRepository { get; private set; }
        public CancellationToken SearchToken { get; private set; } public CancellationToken TagsToken { get; private set; }
        public Func<string, Task<IReadOnlyList<ContainerRegistryImage>>> Search { get; set; } = _ => Task.FromResult<IReadOnlyList<ContainerRegistryImage>>([Image("synthetic/a"), Image("synthetic/b")]);
        public Func<string, Task<IReadOnlyList<string>>> Tags { get; set; } = _ => Task.FromResult<IReadOnlyList<string>>(["latest", "v1"]);
        protected override object? Invoke(MethodInfo? method, object?[]? args)
        {
            switch (method!.Name)
            {
                case "get_CanBrowseRegistry": return Available;
                case "SearchRegistryAsync": Searches++; SearchToken = (CancellationToken)args![1]!; return Search((string)args[0]!);
                case "LoadRegistryTagsAsync": TagReads++; TagsToken = (CancellationToken)args![1]!; LastRepository = (string)args[0]!; return Tags(LastRepository);
                default: throw new NotSupportedException(method.Name);
            }
        }
    }
}
