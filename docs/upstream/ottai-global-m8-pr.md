This is a follow-up to your [xDrip4iOS PR #736](https://github.com/JohanDegraeve/xdripswift/pull/736), based on its current `feat/ottai-syai` head (`d0e212a`). It targets your branch so these changes can be reviewed and folded into the existing contribution rather than duplicating the original driver upstream.

The original Swift Bluetooth implementation and its JugglucoNG attribution are retained. This adds the native Ottai Global M8 client flow:

- Native `/user/login/variousLogin` authentication, mobile client identity and protected regional HTTP transport instead of persisting a web token as a mobile session.
- Binding/history validation before committing credentials, account sensor selection, and guards against stale responses after an account, region or peripheral change.
- Preservation of existing BLE material when an account token expires; new peripherals no longer inherit the last sensor's Cloud ID.
- Global M8 authInfo/activation/bind handling with persisted attempt state and recovery checks to avoid blindly repeating an activation after an uncertain response.
- Manufacturer/server preheat guards: at least 60 minutes rather than accepting readings after the previous ten-minute suppression window. Regional warmup behavior needs hardware review.

Validation on this exact scoped branch:

- **128 Ottai-focused XCTest cases passed**, no failures or skips: Global login, account sensors, regional transport/security, login state, server activation policy and startup backfill.
- Unsigned Simulator application and extension build succeeded with Xcode 27.0 / iOS 27. An isolated test bundle identifier was supplied on the command line; repository signing settings were not changed.
- Source diff and targeted privacy checks completed. No other CGM drivers, Core Data model changes, personal identifiers, signing configuration, branding, SDK binaries or patient logs are included.

Device evidence comes from the personal integration carrying this implementation: one real Global account successfully signed in, fetched the current sensor and its material, and received live/history readings from an already active Ottai M8 over Bluetooth. No account credentials, responses or glucose screenshots are attached.

**Draft limitation:** starting a new unactivated M8 and exercising activation/recovery on hardware have not been verified. Those paths currently have synthetic test coverage only. This is not a claim of hardware coverage for every Ottai/Syai region or firmware, or of supported reset/extension behavior.


Opened: https://github.com/luborjurena/xdripswift/pull/1
