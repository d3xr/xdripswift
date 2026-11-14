# GS1 CN sensor extension

Extension is in testing. Enable **Extend sensor session (testing)** in the GS1 device card and confirm. After the usual 14-day period, new calculated glucose readings use the same storage, graph, alerts and configured sharing services as earlier readings, including Trio.

This applies to the Chinese AA55/V115G GS1 variant. The extension keeps the original sensor start, minute index and recorded history. It continues reading and calculating the existing session; it does not send a sensor reset or create a new activation.

## Duration and source

The normal profile is 20,160 minutes (14 days). The extended profile accepts indices below 34,301 and an age below 34,301 minutes: 23 days, 19 hours, 41 minutes from the original start. These are total session durations.

The extended duration comes from `expectedLifetime` in [JugglucoNG SibionicsConstants.kt](https://github.com/ctqvva/JugglucoNG/blob/11e6e29db7d9055c8fd2e96261812e16f2095f3d/Common/src/main/java/tk/glucodata/drivers/sibionics/SibionicsConstants.kt). It is the selected community session profile, not a measured hardware maximum. The native library and its source are unchanged. See [native source and rebuilding](../Vendor/GS1Native/README.md).

## Data path

1. `GS1Session.ingest` restores and checks the contiguous raw history, confirms the original start and runs the native V115G calculation. The first caught-up batch establishes a baseline; publication waits for a new live final correction.
2. `GS1Policy.mayPublish` applies warm-up, live/history state, index, age and freshness checks. An extended reading additionally requires permission for the exact sensor code, MAC and Bluetooth identity.
3. `CGMSibionicsTransmitter.publish` rechecks permission and the transport generation on the main queue before session, heartbeat and glucose callbacks. It delivers ordinary `GlucoseData` with the original sensor age.
4. `RootApplicationCoordinator` uses the existing glucose pipeline: calibration policy, Core Data, post-processing, graph, alerts and enabled exports. `LoopManager` shares ordinary glucose and session metadata with Trio.

The maximum accepted sample age is 120 seconds at publication. A missing raw-history segment, conflicting history, failed checkpoint, stale sample or invalid native result still prevents publication. No raw-value substitute is introduced.

## Switching the mode

Permission is stored per sensor under a new preference key. A previous diagnostic-only setting does not enable this mode: the user must explicitly authorize the normal glucose flow.

Turning the mode off stops new extended readings. Turning it off and on also invalidates callbacks already queued under the earlier permission. Accepted readings already stored or shared remain in history.

The selected lifetime is also used in session metadata and expiry displays. Changing the switch updates metadata without marking the sensor as freshly contacted and without changing its start. Readings during the first 14 days continue independently of this switch.

## Implementation map

| File | Responsibility |
|---|---|
| `xDrip/BluetoothTransmitter/CGM/Sibionics/GS1Session.swift` | Lifetime profiles, per-sensor permission and generation, history/native-result acceptance |
| `xDrip/BluetoothTransmitter/CGM/Sibionics/CGMSibionicsTransmitter.swift` | Mode setting, lifetime metadata and main-queue glucose delivery |
| `xDrip/BluetoothTransmitter/CGM/Generic/CGMTransmitterDelegate.swift` | Local session-configuration callback |
| `xDrip/Managers/Application/RootApplicationCoordinator.swift` | Existing glucose pipeline and metadata refresh |
| `xDrip/SwiftUIViews/BluetoothPeripherals/BluetoothPeripheralDetailState.swift` | Device switch and confirmation |
| `xDrip Tests/GS1IntegrationTests.swift` | Session, driver, consent and real storage/alert/Trio pipeline regression tests |

The journal digest revision and Core Data schema are preserved so existing history remains readable. Build and signing steps are in the [README](../README.md#build-with-your-own-signing).

Software tests cover the application paths using fixtures and the native engine. Long-duration use on a physical sensor remains in testing.
