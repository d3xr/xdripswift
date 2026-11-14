# Upstream sync: xDrip4iOS 7.2.1 / custom build 4247

November 14, 2026. [README](../README.md) · [Branch guide](branches.md) · [Sensor implementation handoff](developer-handoff-4246.md).

## Integrated upstream

The custom branch merges all 13 official commits from the previous `ba37f261` base through **`f7447f1c70a194cee1c9c8eea96ebbadf62027b8`**, xDrip4iOS 7.2.1 / 4235. The custom app version is **7.2.1 / 4247**, retaining a monotonically increasing build number.

The upstream changes include:

- Resumption of repeating alarms after audio interruptions, with stale activations and acknowledged alarms remaining cancelled.
- Rearming of an expiry reminder when its deadline changes to a future time, without replaying the same deadline after restart.
- Immediate foreground Live Activity renewal and recovery of its original start time.
- Independent glucose-offset and curve-adjustment controls, validation before Apply changes settings/history, and warning acknowledgements.
- Half-unit basal entries, Watch diagnostics, issue reporting, Nightscout threading improvements and direct setup/help links.

Two textual merge conflicts were resolved: the custom version number and a union of AiDex/Libre3 help-topic expectations. The remaining custom/upstream intersections were reviewed after automatic merge. Driver code, sensor state machines, source journaling, Core Data schemas, native algorithm source and supplied native binaries remain unchanged.

## Custom integration correction

The upstream split adjustment controls introduce two persistent child flags. The existing source-change/automatic-disable paths reset only the old combined flag. This sync resets **all three** flags together, preventing previous editing state from being carried into another sensor or stream.

Three new tests each exercise Ottai, AiDex and GS1 contexts through the actual post-processing manager and synthetic Core Data: independent offset/curve application, atomic rejection of invalid Apply, persistence/reloaded manager behavior and source replacement without rewriting previous history. They do not send BLE commands or test physical sensors.

Two adjustment predicates now pass the original `Date` directly to Core Data. Converting it through Unix seconds could round a fractional timestamp by 119 nanoseconds and miss an exactly equal lookup/replacement boundary. A fourth regression checks both rounding directions after persistence. Reading-history queries retain their documented exclusive lower bound; test samples are placed inside that window.

## Useful work retained from retired branches

`Vendor/GS1Native/rebuild.py` was restored from the earlier public combined-CGM branch, commit `63dc4a9`. It adds a portable static-framework rebuild path with pinned toolchain hashes, relative source paths, output-overwrite refusal and a binary path audit. Five Python boundary tests cover path validation, rejecting a bad download before extraction and preserving an existing output. The supplied native binaries were not rebuilt or replaced.

The old provenance/replay/smoke files are already byte-identical to files in the committed source archive. Old GS1 timeline/pending-correction logic was intentionally not imported: the current session uses index order, accepts valid equal/decreasing source timestamps and requires a new current correction after recovery.

Nine legacy branches were checked against upstream history and current implementations. Calendar, Libre Pro H, sound-test, night display, loop schedule, IOB and Medtrum functionality is already merged or superseded. The remaining old UIKit redesign is an archived UI alternative. See the disposition table in the branch guide.

## Verification scope

The selected run contains **626 XCTest cases: 624 passed, one private replay skipped, one failure**. The failing case is `TroubleshootingLogTests.testLibre3AuthenticationKeepsFailureAndOneRecoveryAcrossReplay`: an `authenticationStarted` row remains alongside failure/recovery. It reproduces with the same event sequence in unmodified official `f7447f1` on the same ARM64 Simulator/SDK. The test was not skipped or weakened; the XCTest command therefore returns a nonzero result. This logging discrepancy was not changed as part of the CGM/upstream integration.

All 11 glucose-adjustment cases passed, including four custom regressions and their Ottai/AiDex/GS1 scenarios. The five Python rebuild-helper boundary tests passed. Initial test failures were investigated rather than waived: reading fixtures were moved inside the documented exclusive window, and the fractional-date predicate bug was corrected with a dedicated persisted-data regression. An unmodified upstream control also reproduces the original repeated-Apply fixture failure.

The regression selection covers the CGM integration/migration suites and the affected upstream alarm, expiry, post-processing, Nightscout, Watch, treatment, help, widget and Live Activity suites. This is not the complete upstream test suite. The private GS1 replay input is not distributed and its test is expected to skip on a clean checkout.

Live Activity payload/warm-up tests are retained. Direct orphan-recovery/manager-throttle behavior has no injectable test boundary in the existing singleton and was not replaced with a simulated payload-only claim. Hardware alarm audibility, BLE/NFC, physical activation and operation beyond a sensor's former deadline remain separate validation tasks.

No phone installation, sensor command or native-core rebuild is part of this sync. Use your own signing override as described in the README. For rollback, preserve data and use a reviewed Git revert of the sync merge; installing an older app over a newer data schema is not a backup strategy.
