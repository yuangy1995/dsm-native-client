# Community compatibility participation and testing

[简体中文](COMMUNITY_COMPATIBILITY_GUIDE_ZH.md)

A community report records an observation for one version combination. It is not maintainer device acceptance and cannot raise private-API evidence levels. See [maintainer compatibility evidence](DSM_COMPATIBILITY_MATRIX.md) and the [reviewed community matrix](COMMUNITY_COMPATIBILITY_MATRIX_EN.md).

## Submission and privacy

Use the GitHub “社区兼容性报告 / Community compatibility report” form, or submit a structured report PR based on the [example](../../contracts/community-compatibility/examples/example-report.json). macOS Settings can prepare and preview a local draft for confirmed export. The app does not automatically upload or persist it. Drafts omit the maintainer fields `reportId`, `sourceRef`, `reviewStatus`, and `supersedes`.

- Test only an authorized NAS, account, and data with a released build without temporary debugging code. Writes use dedicated disposable items. Choose `skipped` if safety is uncertain.
- Record only client version/commit/platform, public product model, CPU architecture, full DSM and relevant package versions, and connection, permission, and certificate categories. The [submission schema](../../contracts/schemas/community-compatibility-submission.schema.json) and [formal report schema](../../contracts/schemas/community-compatibility-report.schema.json) define the complete fields.
- Never include device names, serial numbers, MAC addresses, hosts, ports, QuickConnect IDs, accounts, credentials, certificates, share names, paths, filenames, messages, or environment variables. Logs, screenshots, HAR/PCAP captures, responses, crash dumps, user files, and free-form failure diagnostics are not accepted.
- `failed` and `partial` require one `failure` object; other statuses prohibit it. Allowed fields are `stage`, `errorCategory`, `apiName`, `apiVersion`, `httpStatus`, `retryPerformed`, and `rawResponseIncluded: false`, within schema limits. Use `unknown` for API/version and `null` for HTTP status when the app provides no safe value. Do not inspect raw responses to fill metadata.
- Do not add `message`, `body`, `path`, `host`, or raw error text. Follow [SECURITY.md](../../SECURITY.md) for a separate bug report or private disclosure. Never copy suspected secrets into comments or another system.

`schemaVersion: 2` identifies the format; `testSuiteVersion` identifies the checklist. Version 1 requires all 14 results; version 2 requires all 19, including checks not performed. The five version 2 `desktop-drive.*` capabilities currently describe macOS Finder results only. Other platforms must use `not-supported`; this does not mean those platforms lack system file integration. The [capability registry](../../contracts/community-compatibility/capabilities.json) is authoritative.

## Checks and outcomes

Prepare an empty test folder and small synthetic files, preferably using a normal account. Test OTP only if already enabled; do not change authentication or permissions for the report.

| Result | Meaning |
| --- | --- |
| `passed` | Every step completed and matched the UI |
| `failed` | The operation could not complete or produced a wrong result |
| `partial` | Only part worked or results were inconsistent |
| `skipped` | Not performed, unsuitable conditions, or voluntarily skipped |
| `not-supported` | The platform/environment explicitly does not support it |

| Capability ID | Action and expected result |
| --- | --- |
| `connection.resolve` | Find and identify the intended NAS before sending credentials; report only the connection category |
| `authentication.password` | Sign in normally; never record the account, password, or raw error |
| `authentication.otp` | Complete existing two-factor sign-in, otherwise skip |
| `authentication.restore-session` | Close and reopen normally; restore or request sign-in according to settings, without switching account/NAS |
| `files.list-shares` | Show shares available to the account; omit their names |
| `files.browse` | Enter an authorized folder and return; listing and navigation work |
| `files.search` | Find and open a disposable item inside the test folder; omit the query |
| `files.download` | Download a small non-sensitive file; it completes and opens |
| `files.upload` | Upload a test file; the complete item is visible on the NAS |
| `files.create-folder` | Create an empty test folder; it remains after refresh |
| `files.rename` | Rename a test item; the new name appears and the old disappears |
| `files.copy-move` | Copy/move between test folders; the target appears, and a move also removes the source |
| `files.recycle` | Only with an existing recycle bin: confirm deletion before the item leaves its location; otherwise skip/use unsupported, never permanently delete |
| `files.restore` | Restore the preceding test item to the intended location without overwriting real files |
| `desktop-drive.mount` | With a properly signed macOS build, add/remove a mapping; the Finder entry appears/disappears without changing NAS files |
| `desktop-drive.browse` | Scroll through at least 1,000 synthetic Finder items and switch folders; remain responsive and stop loading after leaving |
| `desktop-drive.download-resume` | Interrupt a disposable large-file download and reopen; reuse progress and verify complete content; omit names/checksums |
| `desktop-drive.keep-offline` | Keep offline, cancel, restart to completion, read offline, then release; low space gives recovery guidance without breaking other mappings |
| `desktop-drive.upgrade-restore` | Upgrade from the previous public version in place; mapping, pause state, cache policy, and browsing remain; recreating a mapping is not recovery |

All write checks are optional. Never use production data, the only copy, or a working share. For macOS cloud-drive checks without a properly signed build, use `skipped`; ordinary browsing or temporary signatures cannot establish a Finder result. Clean up test items and local downloads through normal UI without emptying a recycle bin for the report. If cleanup fails, stop dangerous retries and record an allowlisted failure with `stage: cleanup`.

## Maintainer review

| Status | Meaning |
| --- | --- |
| `submitted` | Submitted, not reviewed |
| `reviewed` | Structure, version, and privacy checks passed; observation accuracy is not guaranteed |
| `corroborated` | At least two different contributors reported matching results for the same combination |
| `maintainer-verified` | Reproduced by a maintainer in a recorded environment |
| `disputed` | Reports for the same combination conflict |
| `superseded` | Explicitly replaced by a newer report for the same environment |

Preserve failures and conflicts rather than taking a majority vote. A combination includes model, architecture, DSM build/update, client platform and version, plus package versions for package capabilities. Add a new report after upgrades; do not overwrite history. Maintainers set `supersedes` explicitly and mark its targets `superseded`. Validation blocks dangling references, self-reference, cycles, reversed dates, and superseded reports without successors; it never infers relationships from dates or models.

Administrators may configure the `compatibility-report` and `needs-review` labels. Review public-source privacy manually, then use the read-only candidate helper on a safe submission:

```bash
python3 tools/community-compatibility/prepare_candidate.py \
  --submission /path/to/submission.json --source-ref issue-123 \
  --submitted-at 2026-08-04 --confirm-privacy-reviewed --format diff
python3 tools/community-compatibility/validate.py
python3 tools/community-compatibility/validate_submission.py /path/to/submission.json
python3 tools/community-compatibility/generate.py
```

The helper allocates the next `cc-NNNNNN` after the highest ID without reusing gaps. It writes candidate report/matrix diffs to standard output only: no repository writes, network, Git, or whole-Issue/attachment parsing. Review and apply changes explicitly, then assign the supported evidence status. Formal data lives in `contracts/community-compatibility/reports/`. The [Chinese](COMMUNITY_COMPATIBILITY_MATRIX_ZH.md) and [English](COMMUNITY_COMPATIBILITY_MATRIX_EN.md) matrices are generated; do not edit them directly. Commit only safe structured data and generated results, never raw attachments.

There is no automatic telemetry, report upload, or bypass of manual privacy review. New package checks, statistics, or displays must evolve the same contract. Report counts are not market share, an overall success rate, or permission to enable internal writes.
