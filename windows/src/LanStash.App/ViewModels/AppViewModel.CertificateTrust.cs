using LanStash.App.Features.Authentication;
using LanStash.App.Localization;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.App.ViewModels;

public sealed partial class AppViewModel
{
    private readonly ICertificatePinStore _certificatePins = new FileCertificatePinStore(
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "LanStash",
            "CertificatePins"));
    private CertificateTrustPresentation? _certificateTrust;
    private CertificateTrustRetryContext? _certificateRetry;
    private CancellationTokenSource? _certificateConfirmation;

    internal CertificateTrustPresentation? CertificateTrust
    {
        get => _certificateTrust;
        private set => SetProperty(ref _certificateTrust, value);
    }

    public DsmConnectionSource? ActiveConnectionSource { get; private set; }

    private async Task<CertificateConnectionContext> CreateCertificateConnectionAsync(
        Guid profileId,
        CancellationToken cancellationToken)
    {
        var pin = await _certificatePins.LoadAsync(profileId, cancellationToken)
            .ConfigureAwait(true);
        cancellationToken.ThrowIfCancellationRequested();
        return new CertificateConnectionContext(profileId, pin);
    }

    private void PublishCertificateChallenge(
        ConnectionAttemptLease attempt,
        ConnectAttempt input,
        CertificateTrustChallenge challenge)
    {
        if (challenge.ProfileId != input.Profile.Id ||
            !_connectionAttempts.IsCurrent(attempt))
        {
            return;
        }
        var prompt = new CertificateTrustPresentation(
            Guid.NewGuid(),
            attempt.Id,
            input.Profile.Id,
            input.Profile.DisplayName,
            input.Profile.Host,
            challenge,
            CertificateTrustRetryKind.Connect);
        _certificateRetry = new CertificateTrustRetryContext(prompt, input, null, false);
        CertificateTrust = prompt;
        ErrorMessage = null;
    }

    private void PublishCertificateChallenge(
        ConnectionAttemptLease attempt,
        NasProfile profile,
        bool fallbackToPassword,
        CertificateTrustChallenge challenge)
    {
        if (challenge.ProfileId != profile.Id ||
            !_connectionAttempts.IsCurrent(attempt))
        {
            return;
        }
        var prompt = new CertificateTrustPresentation(
            Guid.NewGuid(),
            attempt.Id,
            profile.Id,
            profile.DisplayName,
            profile.Host,
            challenge,
            CertificateTrustRetryKind.Restore);
        _certificateRetry = new CertificateTrustRetryContext(
            prompt,
            null,
            profile,
            fallbackToPassword);
        CertificateTrust = prompt;
        ErrorMessage = null;
    }

    internal async Task<bool> ConfirmCertificateTrustAsync(Guid promptId)
    {
        var context = _certificateRetry;
        var presentation = CertificateTrust;
        if (context is null ||
            context.Prompt.Id != promptId ||
            presentation is null ||
            presentation.Id != promptId ||
            presentation.AttemptId != context.Prompt.AttemptId ||
            presentation.Challenge != context.Prompt.Challenge ||
            context.Prompt.ProfileId != context.Prompt.Challenge.ProfileId ||
            !context.Prompt.Challenge.CanApprove ||
            context.Prompt.Challenge.Kind == CertificateTrustChallengeKind.InvalidCertificate ||
            context.Prompt.Challenge.ConnectionSource == DsmConnectionSource.QuickConnectRelay)
        {
            return false;
        }

        var confirmation = new CancellationTokenSource();
        var previousConfirmation = Interlocked.Exchange(
            ref _certificateConfirmation,
            confirmation);
        previousConfirmation?.Cancel();
        previousConfirmation?.Dispose();
        try
        {
            await _certificatePins.SaveAsync(
                context.Prompt.ProfileId,
                context.Prompt.Challenge.PresentedFingerprint,
                confirmation.Token).ConfigureAwait(true);
            confirmation.Token.ThrowIfCancellationRequested();
            if (CertificateTrust?.Id != promptId ||
                _certificateRetry != context)
            {
                return false;
            }
            CertificateTrust = null;
            _certificateRetry = null;
            if (context.Connect is not null)
            {
                await ConnectFrozenAttemptAsync(
                    context.Connect,
                    certificateRetry: true).ConfigureAwait(true);
            }
            else if (context.RestoreProfile is not null)
            {
                await RestoreFrozenAttemptAsync(
                    context.RestoreProfile,
                    context.RestoreFallbackToPassword,
                    certificateRetry: true).ConfigureAwait(true);
            }
            return ActiveProfile?.Id == context.Prompt.ProfileId;
        }
        catch (OperationCanceledException) when (confirmation.IsCancellationRequested)
        {
            return false;
        }
        catch
        {
            ErrorMessage = LocalizationService.Current.Get("CertificateTrustRetryFailedMessage");
            return false;
        }
        finally
        {
            if (ReferenceEquals(
                    Interlocked.CompareExchange(
                        ref _certificateConfirmation,
                        null,
                        confirmation),
                    confirmation))
            {
                confirmation.Dispose();
            }
        }
    }

    internal void CancelCertificateTrust(Guid? promptId = null)
    {
        if (promptId is not null && CertificateTrust?.Id != promptId)
        {
            return;
        }
        ClearCertificateChallenge();
    }

    private void ClearCertificateChallenge(Guid? profileId = null)
    {
        var challengeProfileId =
            CertificateTrust?.ProfileId ?? _certificateRetry?.Prompt.ProfileId;
        if (profileId is not null && challengeProfileId != profileId)
        {
            return;
        }
        CertificateTrust = null;
        _certificateRetry = null;
        var confirmation = Interlocked.Exchange(ref _certificateConfirmation, null);
        confirmation?.Cancel();
        confirmation?.Dispose();
    }

    private sealed record CertificateTrustRetryContext(
        CertificateTrustPresentation Prompt,
        ConnectAttempt? Connect,
        NasProfile? RestoreProfile,
        bool RestoreFallbackToPassword);
}

internal sealed class CertificateConnectionContext : IDisposable
{
    private HttpClient? _httpClient;

    internal CertificateConnectionContext(
        Guid profileId,
        CertificateFingerprint? pinnedFingerprint)
    {
        _httpClient = new HttpClient(
            new WindowsCertificateTrustHandler(profileId, pinnedFingerprint))
        {
            Timeout = TimeSpan.FromSeconds(45),
        };
        Api = new DsmApiClient(_httpClient);
        Resolver = new DsmConnectionResolver(
            Api,
            new DsmQuickConnectResolver(_httpClient));
    }

    internal IDsmApiClient Api { get; }
    internal DsmConnectionResolver Resolver { get; }

    internal HttpClient TakeOwnership() =>
        Interlocked.Exchange(ref _httpClient, null) ??
        throw new ObjectDisposedException(nameof(CertificateConnectionContext));

    public void Dispose() => Interlocked.Exchange(ref _httpClient, null)?.Dispose();
}
