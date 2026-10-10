# Contributing

[简体中文](CONTRIBUTING.md)

## Working in this repository

Work on the existing `main` branch. Read [AGENTS.md](AGENTS.md), inspect the working tree and relevant diffs, and preserve existing changes. Do not automatically create feature or temporary validation branches.

When the user explicitly requests a commit, commit the task-related changes on `main` and push to `origin/main`: complete appropriate checks, inspect incoming remote commits, and integrate through normal history. Do not force-push or rewrite shared history. Without a request, do not stage, commit, push, or create a PR. A commit request does not authorize releases, tags, or PRs.

## Commit requirements

- Keep each commit focused on one clear objective.
- Update the relevant documentation, contracts, and progress status when behavior changes.
- Before committing, confirm that no secret, real response, network capture, or user file is present.
- Write code comments in Simplified Chinese. Follow each platform language's conventions for public type and method names.

## API changes

An API-related change must state:

- Whether the API is public, mixed, or internal.
- The verified DSM build and package version.
- Request version, path, parameter encoding, and error handling.
- The fallback behavior when the capability is unavailable.

## Pull Requests

A Pull Request must describe the change, affected platforms, validation performed, security impact, and documentation updates.

## Community compatibility reports

Most users should use the GitHub “社区兼容性报告 / Community compatibility report” form. Read these documents before testing:

- [`Community Compatibility Program`](docs/compatibility/COMMUNITY_COMPATIBILITY_PROGRAM_EN.md)
- [`Community Compatibility Test Guide`](docs/compatibility/COMMUNITY_TEST_GUIDE_EN.md)

Contributors familiar with GitHub may submit a structured report Pull Request based on [`example-report.json`](contracts/community-compatibility/examples/example-report.json). Every report must complete a manual privacy review and pass:

```bash
python3 tools/community-compatibility/validate.py
python3 tools/community-compatibility/generate.py
python3 -m unittest discover -s tools/community-compatibility/tests -p 'test_*.py'
```

A community report must not contain logs, screenshots, HAR files, raw DSM responses, credentials, addresses, unique device identifiers, accounts, real file names, or paths. Do not edit either generated matrix directly.
