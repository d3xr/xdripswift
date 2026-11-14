# Ottai: native Global login and recoverable sensor setup

This updates the follow-up to [#736](https://github.com/JohanDegraeve/xdripswift/pull/736) on top of `feat/ottai-syai@117ba32`. Your latest changes are included; the diff contains the additional Ottai work from my fork.

- Native Global mobile login, validated account sessions and sensor selection. A failed mobile login no longer saves a web token as a mobile session.
- Account and sensor checks reject stale callbacks and keep existing BLE keys when a cloud session expires.
- Persistent preparation and activation state, recovery after uncertain responses, and exact lifetime read-back. CN/Global can request 30 days total while preserving the original start; Syai keeps its manufacturer lifetime.
- Both the current Syai V3 factory flow and the legacy server flow are retained. Setup includes optional passive NFC wake for CN/Syai and a warmup display matching the reading guard.

Validation on this exact PR branch: **277 XCTest cases passed, no failures or skips**, including 233 Ottai cases and 44 shared integration cases. Simulator app, extensions and test bundle built with Xcode 27 / iOS 27 using an isolated app identity. No other CGM drivers, database models, branding, personal signing or patient data are included.

I tested Global login and live/history readings on my own already active Ottai M8 in my personal build. Fresh-sensor activation, NFC wake and operation beyond the original expiry still need physical testing. The original Swift driver and JugglucoNG attribution are retained.

PR: https://github.com/luborjurena/xdripswift/pull/1
