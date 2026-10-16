<!-- doc-role: entrypoint -->
<!-- last-reviewed: 2026-10-16 -->

# LanStash

[简体中文](README.md) · [English](README.en.md)

LanStash is an open-source native client for Synology DSM on macOS, iPhone, iPad, Android, and Windows. Apple clients use Swift/SwiftUI, Android uses Kotlin/Jetpack Compose, and Windows uses C#/WinUI 3. They share API contracts and follow each platform's native interaction patterns.

Features cover files, Synology Photos, Chat, downloads, NAS settings, packages, containers, and virtual machines. The [platform feature table](docs/progress/PLATFORM_MATRIX.md) is the single source for implemented scope, missing capabilities, and protected entry points. See [limitations and remaining work](docs/progress/KNOWN_LIMITATIONS.md) for known issues and real-environment validation conditions. An implementation does not establish compatibility with every DSM, package, or device combination.

## Getting started

| Topic | Reference |
| --- | --- |
| Apple usage, builds, and tests | [Apple](apple/README.md), [macOS](apple/Apps/DsmMac/README.md), [iPhone/iPad](apple/Apps/DsmMobile/README.md) |
| Android builds and tests | [Android](android/README.md) |
| Windows builds and tests | [Windows](windows/README.md) |
| API definitions and evidence | [API index](docs/api/README.md), [shared contracts](contracts/README.md) |
| Published versions | [GitHub Releases](https://github.com/yuangy1995/dsm-native-client/releases) |
| Other maintenance documentation | [Documentation index](docs/README.md) |

## Languages and privacy

English and Simplified Chinese are supported. The first launch follows the system language, falls back to English for unsupported languages, and allows a local language override. See the [locale contract](contracts/localization/README.md).

Official Synology APIs take priority; internal APIs are identified explicitly. High-impact writes require permission checks, appropriate confirmation, duplicate-submission protection, and result verification. Never publicly submit credentials, sessions, real hosts or paths, raw responses, or captures. See the [security policy](SECURITY.md).

Read [AGENTS.md](AGENTS.md) and [Contributing](CONTRIBUTING.en.md) before development. To contribute sanitized results from another NAS environment, follow the [community compatibility guide](docs/compatibility/COMMUNITY_COMPATIBILITY_GUIDE_EN.md).

This project and its history are licensed under [Apache License 2.0](LICENSE).
