# xDrip+ for iOS

[Русская версия](README.ru.md)

Read glucose from CGM sensors over Bluetooth and share it with Trio. This fork extends [xDrip4iOS](https://github.com/JohanDegraeve/xdripswift) with Ottai/Syai, Sibionics GS1 CN and AiDex/LinX/LumiFlex support.

Use the default **`custom-build`** branch to build the complete app.

## What this fork adds

| Sensors | Added functionality |
|---|---|
| **Ottai CN and Global** | Bluetooth readings, account login, preparation and activation of supported new sensors from inside xDrip, and controls for requesting a longer lifetime |
| **Syai** | Bluetooth readings and activation using a manufacturer account |
| **Sibionics GS1 CN** | Direct Bluetooth readings, local glucose calculation, history recovery and sharing with Trio |
| **AiDex X, LinX and LumiFlex** | Bluetooth drivers with sensor identification, warm-up and glucose-data handling |

The integration also preserves the original sensor start time and history during GS1 recovery and fixes the widget displaying sample glucose instead of current readings.

### Ottai activation and lifetime

For a supported **new Ottai CN or Global sensor**, xDrip provides its own preparation and activation flow. A manufacturer account and internet access are still required. A sleeping CN sensor also needs an NFC wake, either from xDrip with suitable signing or from an external reader.

At first activation, the app requests **up to 30 days total**. It reads the lifetime setting back from the sensor and checks the result before continuing with activation. An explicitly rejected request may fall back to a shorter supported duration.

For an **already active Ottai CN or Global**, the device card offers **Request 30 days total**. The request keeps the original start time and history. It does not give the sensor another 30 days or start a new session. The app reads back the setting and checks that the sensor remains active.

**Ottai activation and extension are in testing.** Syai retains its manufacturer-defined activation duration.

### GS1 and Trio

GS1 CN readings are calculated locally using the included native library. Reading an already running GS1 and sharing its glucose with Trio have been checked on an iPhone. Support is limited to the Chinese AA55/V115G variant.

Enable extension in the GS1 device card to continue after 14 days. Fresh calculated readings go to the main graph, alerts and Trio. **Extension is in testing.**

## Build with your own signing

The build has been checked on an Apple silicon Mac with Xcode 27. Python 3 is required by the build script. The included GS1 library supports ARM64 iPhone builds and the Apple silicon Simulator; a normal app build does not require Kotlin or rebuilding that library.

```sh
git clone --branch custom-build https://github.com/d3xr/xdrip-plus.git xdrip-plus
cd xdrip-plus
cp xDripConfigOverride.xcconfig.example xDripConfigOverride.xcconfig
```

Set your Apple Developer Team in the local `xDripConfigOverride.xcconfig`:

```text
XDRIP_DEVELOPMENT_TEAM = YOURTEAMID
```

Open `xdrip.xcworkspace`, select the `xdrip` scheme and configure signing for the app and its extensions. The main app uses HealthKit, App Groups and NFC tag reading. Sharing with your Trio installation requires compatible signing and App Groups.

You can build in Xcode or run:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
bash scripts/build-local.sh
```

The script builds a signed `.app` and prints its location. Installation is a separate step. Keep your signing keys, provisioning files and local override out of Git.

**Personal Team:** use the [local signing profile](docs/build-profiles.md#локальный-personal-team). It leaves NFC disabled while retaining Bluetooth and lifetime controls. To use NFC from xDrip, sign with a profile that permits NFC tag reading.

## Connect a sensor

1. Open **Devices**, add the matching sensor type and enter its code or account details.
2. Connect an already active sensor to read it. For a new Ottai, sign in to the correct regional account, wake the sensor if necessary, connect and select **Start / activate sensor**.
3. Open **Settings → OS-AID Share → Share with OS-AID** and select **Trio** to share normal glucose readings with your compatible Trio installation.

New-sensor activation, NFC and AiDex-family support are in testing.

## Technical documentation

- [Signing profiles and capabilities](docs/build-profiles.md)
- [Ottai activation and lifetime behavior](docs/ottai-activation.md)
- [GS1 extension and data flow](docs/gs1-extension.md)
- [GS1 native library, source and rebuilding](Vendor/GS1Native/README.md)
- [Upstream user guide](https://xdrip4ios.readthedocs.io/en/latest/)

## Credits and license

Built on xDrip4iOS, incorporating the community [Ottai/Syai](https://github.com/JohanDegraeve/xdripswift/pull/736) and [AiDex/LinX](https://github.com/JohanDegraeve/xdripswift/pull/740) integrations. GS1 calculation derives from JugglucoNG; its corresponding source and [notices](Vendor/GS1Native/NOTICE.md) are included.

The project is distributed under [GPLv3](LICENSE). The GS1 core is community reverse engineering, not an official manufacturer SDK.
