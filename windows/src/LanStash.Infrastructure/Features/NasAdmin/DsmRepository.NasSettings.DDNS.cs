using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public async Task<IReadOnlyList<NasDDNSProvider>> LoadDDNSProvidersAsync(
        CancellationToken cancellationToken = default)
    {
        if (!Supports("SYNO.Core.DDNS.Provider"))
        {
            return [];
        }

        try
        {
            var data = await CallFirstAsync(
                "SYNO.Core.DDNS.Provider",
                ["list"],
                parameters: null,
                cancellationToken: cancellationToken).ConfigureAwait(false);

            return data.Array("providers").OfType<JsonObject>()
                .Select(item => new NasDDNSProvider(
                    item.String("id") ?? item.String("name") ?? "unknown",
                    item.String("name") ?? item.String("id") ?? "unknown",
                    item.String("service_url") ?? item.String("url")))
                .ToArray();
        }
        catch (DsmException)
        {
            return [];
        }
    }

    public async Task<IReadOnlyList<NasDDNSRecord>> LoadDDNSRecordsAsync(
        CancellationToken cancellationToken = default)
    {
        if (!Supports("SYNO.Core.DDNS.Record"))
        {
            return [];
        }

        try
        {
            var data = await CallFirstAsync(
                "SYNO.Core.DDNS.Record",
                ["list"],
                parameters: null,
                cancellationToken: cancellationToken).ConfigureAwait(false);

            return data.Array("records").OfType<JsonObject>()
                .Select(item => new NasDDNSRecord(
                    item.String("id") ?? string.Empty,
                    item.String("provider") ?? string.Empty,
                    item.String("hostname") ?? string.Empty,
                    item.String("username") ?? string.Empty,
                    item.String("ip"),
                    item.String("status"),
                    item.Bool("enable") ?? false,
                    item.Bool("heartbeat") ?? false))
                .ToArray();
        }
        catch (DsmException)
        {
            return [];
        }
    }

    public Task<MutationResult> SaveDDNSRecordAsync(
        NasDDNSDraft draft,
        string? existingRecordId = null,
        CancellationToken cancellationToken = default)
    {
        if (!draft.IsValidForSubmission)
        {
            return Task.FromResult(ConfirmedFailureResult(
                "saveDDNS", MutationErrorCategory.Validation, "ddns.save.validation"));
        }

        if (!WriteAvailabilityForDDNS())
        {
            return Task.FromResult(UnsupportedResult("saveDDNS"));
        }

        var parameters = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["provider"] = draft.ProviderId!,
            ["hostname"] = draft.Hostname!,
            ["username"] = draft.Username!,
            ["passwd"] = draft.Password!,
            ["enable"] = draft.IsEnabled ? "true" : "false",
            ["heartbeat"] = draft.Heartbeat ? "true" : "false",
        };

        if (!string.IsNullOrWhiteSpace(draft.ExternalIp))
        {
            parameters["ip"] = draft.ExternalIp;
        }

        var method = existingRecordId is not null ? "set" : "create";
        if (existingRecordId is not null)
        {
            parameters["id"] = existingRecordId;
        }

        return SaveDdnsAsync(method, parameters, existingRecordId, draft, cancellationToken);
    }

    public Task<MutationResult> DeleteDDNSRecordAsync(
        string recordId,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(recordId))
        {
            return Task.FromResult(ConfirmedFailureResult(
                "deleteDDNS", MutationErrorCategory.Validation, "ddns.delete.validation"));
        }

        if (!WriteAvailabilityForDDNS())
        {
            return Task.FromResult(UnsupportedResult("deleteDDNS"));
        }

        return DeleteDdnsAsync(recordId, cancellationToken);
    }

    public Task<MutationResult> TestDDNSRecordAsync(
        string recordId,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(recordId))
        {
            return Task.FromResult(ConfirmedFailureResult(
                "testDDNS", MutationErrorCategory.Validation, "ddns.test.validation"));
        }

        if (!WriteAvailabilityForDDNS())
        {
            return Task.FromResult(UnsupportedResult("testDDNS"));
        }

        return TestDdnsAsync(recordId, cancellationToken);
    }

    public Task<MutationResult> UpdateDDNSAddressAsync(
        string recordId,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(recordId))
        {
            return Task.FromResult(ConfirmedFailureResult(
                "updateDDNSAddress", MutationErrorCategory.Validation,
                "ddns.update-address.validation"));
        }
        if (!WriteAvailabilityForDDNS())
        {
            return Task.FromResult(UnsupportedResult("updateDDNSAddress"));
        }

        return UpdateDdnsAsync(recordId, cancellationToken);
    }

    private bool WriteAvailabilityForDDNS() =>
        NasSettingsWritesEnabled &&
        ((INasSettingsRepository)this).WriteAvailability.CanSaveDDNS;

    private async Task<MutationResult> SaveDdnsAsync(
        string method,
        IReadOnlyDictionary<string, string> parameters,
        string? existingRecordId,
        NasDDNSDraft draft,
        CancellationToken cancellationToken)
    {
        var result = await SaveSettingsAsync(
            "SYNO.Core.DDNS.Record", method, parameters, "saveDDNS",
            async ct =>
            {
                var records = await LoadDDNSRecordsAsync(ct).ConfigureAwait(false);
                var match = records.Where(record =>
                        (existingRecordId is null || record.Id == existingRecordId) &&
                        string.Equals(record.ProviderId, draft.ProviderId, StringComparison.Ordinal) &&
                        string.Equals(record.Hostname, draft.Hostname, StringComparison.Ordinal) &&
                        string.Equals(record.Username, draft.Username, StringComparison.Ordinal) &&
                        record.IsEnabled == draft.IsEnabled &&
                        record.Heartbeat == draft.Heartbeat)
                    .ToArray();
                if (match.Length != 1)
                {
                    throw new InvalidDataException("ddns.save.readback-mismatch");
                }
            }, cancellationToken).ConfigureAwait(false);
        return result;
    }

    private async Task<MutationResult> DeleteDdnsAsync(
        string recordId,
        CancellationToken cancellationToken)
    {
        var parameters = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["id"] = JsonSerializer.Serialize(new[] { recordId }),
        };
        return await SaveSettingsAsync(
            "SYNO.Core.DDNS.Record", "delete", parameters, "deleteDDNS",
            async ct =>
            {
                if ((await LoadDDNSRecordsAsync(ct).ConfigureAwait(false)).Any(r => r.Id == recordId))
                {
                    throw new InvalidDataException("ddns.delete.readback-mismatch");
                }
            }, cancellationToken).ConfigureAwait(false);
    }

    private async Task<MutationResult> TestDdnsAsync(
        string recordId,
        CancellationToken cancellationToken)
    {
        var record = (await LoadDDNSRecordsAsync(cancellationToken).ConfigureAwait(false))
            .SingleOrDefault(item => item.Id == recordId);
        if (record is null)
        {
            return ConfirmedFailureResult("testDDNS", MutationErrorCategory.Validation,
                "ddns.test.record-not-found");
        }
        var parameters = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["provider"] = record.ProviderId,
            ["hostname"] = record.Hostname,
            ["username"] = record.Username,
            ["enable"] = record.IsEnabled ? "true" : "false",
            ["heartbeat"] = record.Heartbeat ? "true" : "false",
        };
        return await SaveSettingsAsync(
            "SYNO.Core.DDNS.Record", "test", parameters, "testDDNS",
            cancellationToken: cancellationToken).ConfigureAwait(false);
    }

    private async Task<MutationResult> UpdateDdnsAsync(
        string recordId,
        CancellationToken cancellationToken)
    {
        var before = await LoadDDNSRecordsAsync(cancellationToken).ConfigureAwait(false);
        if (before.All(item => item.Id != recordId))
        {
            return ConfirmedFailureResult("updateDDNSAddress", MutationErrorCategory.Validation,
                "ddns.update-address.record-not-found");
        }
        return await SaveSettingsAsync(
            "SYNO.Core.DDNS.Record", "update_ip_address",
            new Dictionary<string, string>(StringComparer.Ordinal), "updateDDNSAddress",
            async ct => _ = await LoadDDNSRecordsAsync(ct).ConfigureAwait(false),
            cancellationToken).ConfigureAwait(false);
    }
}
