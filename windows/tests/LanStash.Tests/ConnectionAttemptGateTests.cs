using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.Tests;

public sealed class ConnectionAttemptGateTests
{
    [Fact]
    public void CancelledAttemptCannotPublishState()
    {
        var gate = new ConnectionAttemptGate();
        using var attempt = gate.Begin();

        gate.CancelCurrent();

        Assert.False(gate.IsCurrent(attempt));
        Assert.Throws<OperationCanceledException>(() =>
            gate.ThrowIfNotCurrent(attempt));
        Assert.True(gate.End(attempt));
    }

    [Fact]
    public void ReplacedAttemptCannotEndOrOverwriteCurrentAttempt()
    {
        var gate = new ConnectionAttemptGate();
        using var first = gate.Begin();
        using var second = gate.Begin();

        Assert.True(first.Cancellation.IsCancellationRequested);
        Assert.False(gate.IsCurrent(first));
        Assert.False(gate.End(first));
        Assert.True(gate.IsCurrent(second));
        Assert.True(gate.End(second));
    }

    [Fact]
    public void ConnectAttemptFreezesCredentialsAndPreference()
    {
        var profile = new NasProfile(
            Guid.NewGuid(),
            "NAS A",
            "nas-a.local",
            null,
            "alice",
            true,
            true);
        var passwordField = "password-a";
        var otpField = "123456";
        var rememberField = true;
        var attempt = new ConnectAttempt(
            profile,
            passwordField,
            otpField,
            rememberField);

        passwordField = "password-b";
        otpField = "654321";
        rememberField = false;

        Assert.Equal("nas-a.local", attempt.Profile.Host);
        Assert.Equal("password-a", attempt.Password);
        Assert.Equal("123456", attempt.Otp);
        Assert.True(attempt.RememberPassword);
    }

    [Fact]
    public void OnlyAuthenticationFailuresInvalidateSavedSession()
    {
        var authenticationFailure = new DsmException(
            "expired",
            "sign in again",
            authenticationFailure: true);
        var transientFailure = new DsmException(
            "temporarily unavailable",
            "try again");

        Assert.True(ConnectionRecoveryPolicy.ShouldInvalidateSavedSession(
            authenticationFailure));
        Assert.False(ConnectionRecoveryPolicy.ShouldInvalidateSavedSession(
            transientFailure));
    }
}
