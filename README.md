# xDrip+ for iOS

[Русская версия](README.ru.md) · [Branches and upstream baseline](docs/branches.md)

Custom **xDrip4iOS 7.2.0 / build 4246**, integrating Ottai CN/Global/Syai, Sibionics GS1 CN, AiDex/LinX/LumiFlex and ordinary glucose sharing with Trio. This is an iOS project; it does not use the Android xDrip+ codebase or Android signing keystores.

Use **`custom-build`**, the default branch, for the complete integration. Other branches contain upstream snapshots, individual patches or historical experiments; they are not interchangeable builds.

## Features and verification limits

| Area | Implemented | Verification limit |
|---|---|---|
| Ottai CN/Global | New-sensor BLE preparation and activation, regional cloud credentials and factory parameters; a requested total lifetime of up to 30 days with exact read-back | First physical activation with this version has not been tested; an account, internet access and a supported firmware profile are required |
| Active Ottai | Manual request for a total lifetime of 30 days from the original start, followed by exact read-back and a fresh status-3 check | A stored parameter does not prove that firmware changes its deadline or continues measuring beyond the previous expiry |
| CN/Syai NFC reader | Explicit passive ISO14443 RF session; no proprietary tag commands or automatic BLE activation | Requires an NFC TAG entitlement; reader readiness/tag detection does not prove identity or physical wake |
| Syai | Existing server-assisted activation flow retained | An opaque server-defined duration is not claimed as verified 30-day support |
| GS1 CN AA55/V115G | Direct BLE, a persistent history journal, local native calculation and new final corrections shared with Trio | Reading an already running GS1 has been verified; a new sensor's physical first start has not |
| GS1 after day 14 | Optional final-correction diagnostics in a separate device card, strictly before 23 days 19 hours 41 minutes from the original start | Disabled by default; excluded from ordinary glucose, alerts and Trio. This does not reset or extend firmware lifetime |

The repository includes the **full NFC-enabled profile**. Personal signing settings and Personal Team limitations belong in ignored local overrides. Obtaining a suitable NFC-enabled signing profile requires a rebuild, not a new NFC implementation.

## Build with your own Apple signing identity

Verified environment: **Apple Silicon Mac, Xcode 27.0 / SDK 27.0**, and Python 3. The included GS1 XCFramework provides ARM64 device and Simulator slices; an Intel x86_64 Simulator slice is not included. A normal app build does not require Kotlin, JVM, CocoaPods or rebuilding the native core.

```sh
git clone --branch custom-build https://github.com/d3xr/xdrip-plus.git xdrip-plus
cd xdrip-plus
cp xDripConfigOverride.xcconfig.example xDripConfigOverride.xcconfig
```

Set your own `XDRIP_DEVELOPMENT_TEAM` in the local override. Configure provisioning for the app and extensions, including HealthKit, App Groups and NFC TAG on the main target. Direct sharing with Trio requires compatible signing and App Groups; matching another Team's group name does not grant access to its container. Never commit private signing keys or provisioning files.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
bash scripts/build-local.sh
```

The script builds a Debug `.app`, verifies its signature and prints the package path. It does not install the app or start a sensor. Alternatively, open `xdrip.xcworkspace` and select the `xdrip` scheme.

For a Personal Team, copy `docs/signing/PersonalTeam.entitlements.example` to the ignored root `xDripPersonalTeam.entitlements`, then use `docs/signing/PersonalTeam.xcconfig.example` as your root `xDripConfigOverride.xcconfig` and set your Team. This disables NFC while retaining BLE preparation and lifetime logic. A sleeping CN/Syai then needs an external NFC wake; the investigated Global profile uses BLE without that step.

## Branches and baseline

The integration is based on [upstream xDrip4iOS 7.2.0 / 4234, `ba37f261`](https://github.com/JohanDegraeve/xdripswift/tree/ba37f261352eedfb7f518c4a38e2266acb0f95e9). Ottai/Syai derives from [PR #736](https://github.com/JohanDegraeve/xdripswift/pull/736); AiDex/LinX/LumiFlex derives from [PR #740](https://github.com/JohanDegraeve/xdripswift/pull/740). GS1 uses the pinned community native core and corresponding source included in `Vendor/GS1Native`.

As checked on November 14, 2026, upstream 7.2.1 / 4235 is 13 commits ahead of this base, including alarm, expiry-reminder and Live Activity fixes. Those upstream changes are **not yet integrated** here. Updating this integration requires a reviewed merge or port with regression checks; selecting an older feature branch does not provide the update. See the [branch guide](docs/branches.md).

## Documentation

- [Branch guide and upstream comparison](docs/branches.md) — English.
- [Full technical handoff, sensor flows and build instructions](docs/developer-handoff-4246.md) — Russian.
- [Files changed in the last 4246 implementation stage](docs/changes-4246.md) — Russian; not the full diff from upstream.
- [Full and Personal Team signing profiles](docs/build-profiles.md) — Russian.
- [Ottai activation protocol](docs/ottai-activation.md) — Russian.
- [Public snapshot contents](docs/public-snapshot.md) — Russian.
- [GS1 native source, rebuilding and notices](Vendor/GS1Native/README.md).
- [Upstream documentation](https://xdrip4ios.readthedocs.io/en/latest/).

## Tests and evidence

On the clean public snapshot, **312 targeted XCTest cases passed and one private GS1 replay case was skipped**, with no failures. The skipped test requires personal input deliberately excluded from the repository. The prepared private test environment previously passed all 313 cases, including 43 new tests. These are selected suites, not the complete upstream test suite. An unsigned iPhone Release build also succeeded.

Simulator tests and synthetic HTTP/transport ports verify software behavior. They do not establish real BLE/NFC behavior, first physical activation, measurement accuracy or firmware lifetime extension. ACK, duration read-back and fresh measurements after the previous deadline are separate evidence levels.

## Language and licensing

English is the primary repository documentation language. The app's development language is also English; available translations follow iOS language selection. The build does not force Russian. Detailed Russian documents are retained alongside this English entry point.

The project inherits xDrip4iOS's [GPLv3 license](LICENSE). Ottai/JugglucoNG attribution is retained in source; GS1's [NOTICE](Vendor/GS1Native/NOTICE.md), licenses and corresponding source are included. The GS1 core is community reverse engineering, not an official manufacturer SDK.
