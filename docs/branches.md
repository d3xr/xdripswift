# Branch guide

Checked November 14, 2026. [README](../README.md) · [Technical handoff (Russian)](developer-handoff-4246.md).

## Which branch to use

**Use `custom-build` for the complete custom app.** It contains the 4246 runtime snapshot plus documentation updates. The source was exported as one clean commit on top of public upstream `ba37f261`; the old private Git history and personal signing settings were not imported.

| Branch | Purpose | Why it is not a substitute for custom-build |
|---|---|---|
| `custom-build` | Default branch: Ottai/Syai, GS1 CN, AiDex/LinX/LumiFlex, activation/lifetime work and local signing templates | Current integration |
| `master` | Preserved upstream 7.2.0 / 4234 snapshot at `ba37f261` | Does not contain our additional CGM integrations |
| `develop` | Same preserved snapshot as this fork's master | Its name does not make it newer than custom-build or current upstream |
| `feature/cgm-drivers` | Earlier combined CGM patch, `63dc4a9` | Predates the full 4246 activation/lifetime, recovery and GS1 integration fixes |
| `feature/sibionics-gs1` | Isolated GS1 CN AA55/115G patch, `626b7f1` | GS1-only preview, not the latest combined integration |
| `fix/ottai-global-native-auth` | Scoped Global account/auth/activation follow-up, `961f47f`, based on the Ottai donor branch | No GS1/AiDex integration; predates the full 4246 work |
| `fix/widget-runtime-data` | Scoped fix for synthetic glucose in the widget, `9db7004` | A widget patch, not an alternative CGM app |

The scoped branches support separate review/upstream contributions. They are retained for traceability. In particular, GS1-only and earlier combined branches have different v38 database schemas; switching between them is not a tested data migration.

## Historical branches

These existing branches were preserved during publication. Their names describe old experiments or patches, not recommended current builds. Dates below are tip-commit dates.

| Branch | Tip topic | Date |
|---|---|---|
| `calendar-event-visual-indicator-squash` | Calendar event visual indicator | 2023-01-09 |
| `fastlane` | GitHub token permissions for the older Fastlane workflow | 2023-07-13 |
| `fixiOSVolumeTest` | iOS sound volume-test fix | 2022-06-17 |
| `insulin-on-board` | Historical IOB development | 2022-07-17 |
| `libreproh` | Libre Pro H support work | 2022-04-24 |
| `loopdelayschedule` | Time-dependent loop delay | 2022-07-11 |
| `medtrum-easyview-follower-temp` | Historical Medtrum follower integration | 2025-12-21 |
| `nightmodeWithOnlyValue` | Large landscape-value display | 2024-12-30 |
| `ui-changes` | Historical UI update | 2023-07-10 |

## Why this base, and what should be updated

The tested integration was built from **xDrip4iOS 7.2.0 / 4234**, commit `ba37f261352eedfb7f518c4a38e2266acb0f95e9`. This is the iOS Swift application, unrelated to the Android xDrip+ codebase. The clean public runtime snapshot is `7d837279e8ca6a48958d92800d207754585adc0c`.

Current official upstream master/develop point to **7.2.1 / 4235**, `f7447f1c70a194cee1c9c8eea96ebbadf62027b8`. The [13-commit comparison](https://github.com/JohanDegraeve/xdripswift/compare/ba37f261352eedfb7f518c4a38e2266acb0f95e9...f7447f1c70a194cee1c9c8eea96ebbadf62027b8) includes fixes for silent alarms after audio interruptions, expiry-reminder rearming, Live Activity renewal and other changes. Our corresponding alarm, expiry-reminder and Live Activity files still match the old base.

The appropriate maintenance step is to update **custom-build** against that upstream release, preserving the CGM additions and checking alert, migration, history and sharing behavior. Changing the default to an old feature branch would lose integration work rather than solve the upstream gap. No runtime upgrade or branch deletion was performed as part of this documentation audit.
