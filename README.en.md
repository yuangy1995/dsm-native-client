<!-- doc-role: entrypoint -->
<!-- last-reviewed: 2026-08-20 -->

# LanStash

[简体中文](README.md) · [English](README.en.md)

LanStash is an open-source native client for Synology DSM across five device targets: macOS, iPhone, iPad, Android, and Windows. It does not use a cross-platform UI runtime. Apple clients use Swift and SwiftUI, Android uses Kotlin and Jetpack Compose, and Windows uses C# and WinUI 3.

The three technology stacks share DSM API contracts, error semantics, locale rules, redacted fixtures, and acceptance criteria. Each client still follows its platform's conventions for navigation, windows, touch, keyboard access, accessibility, and secure storage.

## Project status

The current milestone is native-client alignment and device validation across all five targets.

| Client | Technology | Current status |
| --- | --- | --- |
| macOS | Swift 6, SwiftUI, Swift Package Manager | Most mature; primary Files, Photos, Messages, Downloads, Containers, Virtual Machines, and NAS management flows are implemented |
| iPhone | Swift 6, SwiftUI | Mobile flows now cover sign-in, Files, Photos, limited text Chat, common single-task Download Station actions, and read-only management pages; see the [development status](docs/progress/STATUS.md) for exact scope and device-validation gaps |
| iPad | Swift 6, SwiftUI | Shares the universal iPhone project and includes split layouts, keyboard paths, and large-screen adaptation; real iPad and NAS interaction remains tracked in the [development status](docs/progress/STATUS.md) |
| Android | Kotlin, Jetpack Compose | Major native modules and automated safety flows are established; current completion, remaining scope, and device-validation gaps are tracked in the [development status](docs/progress/STATUS.md) |
| Windows | C#, WinUI 3 | Native flows now cover authentication, Files, Photos, limited text Chat, Download Station, local settings, and desktop integration; cloud-build evidence and real-device gaps are tracked in the [development status](docs/progress/STATUS.md) |

“Implemented” means that the source path and automated tests exist. It does not mean that every DSM model, DSM release, or package version has completed device compatibility testing. High-impact writes still require capability discovery, permission checks, user confirmation, duplicate-submission protection, and result verification.

## Main capabilities

- Multiple NAS profiles, HTTPS addresses, and QuickConnect IDs.
- DSM sign-in, two-factor verification, session restoration, and platform secure storage.
- File and shared-folder browsing, search, upload, download, copy, move, rename, compression, extraction, and sharing.
- Photo spaces, thumbnails, timeline browsing, and common media previews.
- Synology Chat conversations, attachments, reminders, polls, and scheduled messages.
- Entry points for Download Station, Container Manager, Virtual Machine Manager, and NAS settings.
- Native management views for storage, packages, accounts, logs, connections, networks, and security.
- Light and dark modes, keyboard and touch input, dynamic type, screen readers, and reduced motion.

Some capabilities depend on DSM or package versions. LanStash prefers Synology's public APIs. Internal APIs are explicitly marked in the implementation and compatibility documentation and isolated behind capability discovery.

## Languages and localization

The initial release supports:

- English (`en`)
- Simplified Chinese (`zh-Hans`)

On first launch, the app follows the system's primary preferred language. English variants use English. Simplified Chinese, mainland China Chinese, and Singapore Chinese use Simplified Chinese. Traditional Chinese and all other unsupported languages fall back to English. A user can explicitly select English or Simplified Chinese in the app. This preference is stored locally and is not tied to a NAS, account, password, or session.

The shared locale contract is [`contracts/localization/supported-locales.json`](contracts/localization/supported-locales.json). Adding a language requires matching Apple, Android, and Windows resources, language selectors, tests, README updates, and platform-matrix updates. Run the following command to detect missing resources, parameter mismatches, invalid references, and visible-text hardcoding:

```bash
python3 tools/localization/check_localization.py
```

## Repository layout

```text
apple/
  Apps/DsmMac/             macOS SwiftUI app
  Apps/DsmMobile/          universal iPhone/iPad SwiftUI app
  Packages/                shared Apple domain, networking, and localization packages
android/                   Android Jetpack Compose app
windows/                   Windows WinUI 3 app
contracts/                 cross-client API, error, and locale contracts
docs/                      architecture, plans, progress, security, and compatibility docs
tools/                     localization, contract, and repository validation tools
```

## Build and test

### Apple

Use a current stable Xcode release and XcodeGen.

```bash
swift test --package-path apple

cd apple/Apps/DsmMac
xcodegen generate
xcodebuild \
  -project DsmMac.xcodeproj \
  -scheme DsmMac \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  build

cd ../DsmMobile
xcodegen generate
xcodebuild \
  -project DsmMobile.xcodeproj \
  -scheme DsmMobile \
  -sdk iphonesimulator \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  build
```

### Android

Use JDK 17 and an Android SDK.

```bash
cd android
./gradlew test assembleDebug
```

### Windows

Use Windows with the .NET 10 SDK and a WinUI 3 build environment.

```powershell
cd windows
dotnet restore LanStash.slnx
dotnet test tests/LanStash.Tests/LanStash.Tests.csproj --configuration Release --no-restore
dotnet build src/LanStash.App/LanStash.App.csproj --configuration Release --runtime win-x64 --no-restore
```

See [`apple/README.md`](apple/README.md), [`android/README.md`](android/README.md), and [`windows/README.md`](windows/README.md) for platform-specific setup. GitHub Actions validates Apple, Android, Windows, and repository-level contracts independently.

## Security and privacy

- Never commit passwords, OTPs, SIDs, SynoTokens, cookies, DIDs, private certificate keys, or real user data.
- Never commit unredacted HAR or PCAP captures, DSM responses, file paths, or host addresses.
- Release builds require HTTPS and do not provide a global certificate-validation bypass.
- Passwords and sessions use platform secure storage only when the user explicitly opts in.
- Destructive operations such as deletion, restoration, and network changes require permission checks, confirmation, duplicate protection, and result verification.
- Real DSM behavior is tested only on dedicated test systems with the DSM build, package versions, and certificate type recorded.

Follow [`SECURITY.md`](SECURITY.md) when reporting a vulnerability. Do not attach real environment data to a public issue.

## Documentation

- [Current development and acceptance plan](docs/development/NATIVE_DSM_FILE_APP_DEVELOPMENT_PLAN_ZH.md)
- [Current progress](docs/progress/STATUS.md)
- [Product roadmap](docs/progress/ROADMAP.md)
- [Platform feature matrix](docs/progress/PLATFORM_MATRIX.md)
- [Android quality baseline](docs/quality/ANDROID_QUALITY_BASELINE_ZH.md)
- [Release and manual-validation history](docs/archive/2026-h2/RELEASE_VALIDATION_HISTORY.md)
- [DSM compatibility matrix](docs/compatibility/DSM_COMPATIBILITY_MATRIX.md)
- [Community Compatibility Program](docs/compatibility/COMMUNITY_COMPATIBILITY_PROGRAM_EN.md)
- [Community Compatibility Matrix](docs/compatibility/COMMUNITY_COMPATIBILITY_MATRIX_EN.md)
- [Architecture](docs/architecture/ARCHITECTURE.md)
- [Security baseline](docs/security/SECURITY_BASELINE.md)
- [DSM Web API reference](docs/api/DSM_WEB_API_REFERENCE_ZH.md)
- [DSM and package private API discovery process](docs/api/discovery/README.md)
- [Locale contract](contracts/localization/README.md)

## Contributing

Read [`AGENTS.md`](AGENTS.md) and [`CONTRIBUTING.en.md`](CONTRIBUTING.en.md) before making changes. Every new or changed user-visible string must have both English and Simplified Chinese resources. Translated strings must never drive business logic, navigation, filtering, persistence, or API parameters.

If you have access to a different Synology NAS model or version, you can also join the [Community Compatibility Program](docs/compatibility/COMMUNITY_COMPATIBILITY_PROGRAM_EN.md). Most users submit redacted results through a bilingual GitHub form; developers may submit validated structured reports. The first phase does not collect logs, screenshots, host information, or real file data.

LanStash is licensed under the [Apache License 2.0](LICENSE).
