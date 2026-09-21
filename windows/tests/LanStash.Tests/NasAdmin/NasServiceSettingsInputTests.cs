using LanStash.App.Features.NasAdmin;
using LanStash.Domain;

namespace LanStash.Tests.NasAdmin;

public sealed class NasServiceSettingsInputTests
{
    [Theory]
    [InlineData("1", 1)]
    [InlineData("2222", 2222)]
    [InlineData("65535", 65535)]
    public void ValidTerminalPortIsPreserved(string text, int port)
    {
        Assert.True(NasServiceSettingsInput.TryTerminal(new(false, 22, false, null),
            true, text, false, out var value));
        Assert.Equal(new NasTerminalSettings(true, port, false, null), value);
    }

    [Theory]
    [InlineData("")]
    [InlineData("0")]
    [InlineData("65536")]
    [InlineData("22.5")]
    [InlineData("-22")]
    [InlineData("+22")]
    [InlineData("1,000")]
    public void InvalidPortsDoNotClampOrSilentlyRetainPreviousValue(string text)
    {
        Assert.False(NasServiceSettingsInput.TryTerminal(new(false, 22, false, null),
            true, text, false, out _));
        Assert.False(NasServiceSettingsInput.TryProxy(new(false, null, null), true,
            "proxy.example.invalid", text, out _));
    }

    [Fact]
    public void TerminalDoesNotInventUnsupportedPort()
    {
        Assert.True(NasServiceSettingsInput.TryTerminal(new(false, null, false, null),
            true, "22", false, out var value));
        Assert.Null(value.SshPort);
        Assert.Null(value.TelnetPort);
    }

    [Theory]
    [InlineData("")]
    [InlineData("https://proxy.example.invalid")]
    [InlineData("proxy.example.invalid/path")]
    [InlineData("proxy.example.invalid?value")]
    [InlineData("proxy.example.invalid#value")]
    [InlineData("user@proxy.example.invalid")]
    [InlineData("proxy.example.invalid:3128")]
    [InlineData("proxy .example.invalid")]
    public void ProxyRejectsNonHostInput(string host)
    {
        Assert.False(NasServiceSettingsInput.TryProxy(new(false, null, null), true, host, "3128", out _));
    }

    [Fact]
    public void ProxyTrimsHostButDisabledProxyOnlyChangesSwitch()
    {
        var baseline = new NasProxySettings(false, null, null);
        Assert.True(NasServiceSettingsInput.TryProxy(baseline, true, " proxy.example.invalid ", "3128", out var enabled));
        Assert.Equal(new NasProxySettings(true, "proxy.example.invalid", 3128), enabled);
        Assert.True(NasServiceSettingsInput.TryProxy(enabled, false, "invalid/path", "", out var disabled));
        Assert.Equal(enabled with { Enabled = false }, disabled);
    }
}
