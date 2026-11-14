# Branch guide

Updated November 14, 2026. [README](../README.md) · [7.2.1 sync and branch audit](upstream-sync-7.2.1.md).

## Current branches

Use **`custom-build`**, the default branch, for the complete app. Its version is 7.2.1 / custom build 4247. `develop` tracks the official upstream release; the other three branches remain unchanged because open pull requests depend on them.

| Branch | Purpose |
|---|---|
| `custom-build` | Full Ottai/Syai, GS1 CN and AiDex/LinX/LumiFlex integration, including our activation/lifetime, NFC, recovery and data-sharing work |
| `develop` | Official upstream 7.2.1 / 4235, `f7447f1`; no custom CGM additions |
| `feature/sibionics-gs1` | Unchanged GS1-only head `626b7f1` for open draft [upstream PR #791](https://github.com/JohanDegraeve/xdripswift/pull/791) |
| `fix/widget-runtime-data` | Unchanged widget-fix head `9db7004` for open [upstream PR #785](https://github.com/JohanDegraeve/xdripswift/pull/785) |
| `fix/ottai-global-native-auth` | Unchanged Ottai donor follow-up `961f47f` for open draft [PR #1](https://github.com/luborjurena/xdripswift/pull/1) |

The pull-request branches are scoped review artifacts, not alternative current app builds. Do not switch an installed database between old GS1-only and combined branches: their v38 schemas differ and that cross-branch migration has not been tested.

## Retired remote branches

All tips were backed up locally before cleanup. No feature was discarded solely because a branch was old: content and upstream history were checked. A clean public snapshot and source archive preserve the current integration without importing the old private Git history.

| Retired branch | Disposition |
|---|---|
| `master` | Duplicate of the old `develop` snapshot; one upstream-tracking branch is sufficient |
| `feature/cgm-drivers` | Earlier combined integration superseded by `custom-build`; its useful portable GS1 `rebuild.py` was recovered before deletion |
| `calendar-event-visual-indicator-squash` | Calendar visual indicator already present in current CalendarManager/settings |
| `fastlane` | Changes already merged into the upstream base |
| `fixiOSVolumeTest` | Sound-test fix already merged into the upstream base |
| `insulin-on-board` | Superseded by the current TherapyMetrics model and its validation/tests |
| `libreproh` | Support already merged into the upstream base |
| `loopdelayschedule` | Patch-equivalent change and current schedule UI/LoopManager already present |
| `medtrum-easyview-follower-temp` | Patient/caregiver selection preserved in the current manager; keep-alive now uses the shared implementation |
| `nightmodeWithOnlyValue` | Changes already merged into the upstream base |
| `ui-changes` | Archived 2023 UIKit redesign; obsolete views are not a missing fix for the current SwiftUI Home |

The repository keeps its tags and the three active PR heads. Future upstream updates belong in `custom-build`; the `develop` reference should move to the matching official commit.
