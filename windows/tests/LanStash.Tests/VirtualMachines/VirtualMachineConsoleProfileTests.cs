using System.Text.Json;
using LanStash.App.Features.VirtualMachines;

namespace LanStash.Tests.VirtualMachines;

public sealed class VirtualMachineConsoleProfileTests
{
    [Fact]
    public void EachWindowOwnsANewFolderAndCannotDeleteAnotherWindowsData()
    {
        var first = VirtualMachineConsoleProfile.Create(); var second = VirtualMachineConsoleProfile.Create();
        try
        {
            Assert.NotEqual(first.DirectoryPath, second.DirectoryPath);
            File.WriteAllText(Path.Combine(first.DirectoryPath, "synthetic.txt"), "first");
            var other = Path.Combine(second.DirectoryPath, "synthetic.txt"); File.WriteAllText(other, "second");
            Assert.True(first.TryDelete()); Assert.False(Directory.Exists(first.DirectoryPath)); Assert.Equal("second", File.ReadAllText(other));
            Assert.True(first.TryDelete());
        }
        finally { first.TryDelete(); second.TryDelete(); }
    }
    [Fact]
    public void EnvironmentOverridesAndParentPathsCannotBeAccepted()
    {
        var profile = VirtualMachineConsoleProfile.Create();
        try
        {
            Assert.True(profile.Matches(profile.DirectoryPath)); Assert.True(profile.Matches(profile.DirectoryPath + Path.DirectorySeparatorChar));
            Assert.False(profile.Matches(Path.GetTempPath())); Assert.False(profile.Matches(Path.GetDirectoryName(profile.DirectoryPath)!));
            Assert.False(profile.Matches(profile.DirectoryPath + "-other")); Assert.Equal("{}", JsonSerializer.Serialize(profile));
            Assert.Equal(nameof(VirtualMachineConsoleProfile), profile.ToString());
        }
        finally { profile.TryDelete(); }
    }
}
