# Do not synthesize glucose when widget data is unavailable

When the shared app-group payload is missing or cannot be decoded, the widget currently creates a random glucose history with a Dexcom G6 label and current timestamps. This also affects non-preview snapshots. A missing collector can therefore appear to have fresh readings.

Use an empty runtime state instead, while retaining demonstration content for WidgetKit previews. Keep values paired with measurement dates, preserve the keep-alive warning, and pass valid glucose, preferences, AID status and therapy metrics through unchanged.

Validation:

- Six `WidgetRuntimeDataTests` passed: missing/corrupt payload, mismatched arrays, valid readings, empty collector data and optional AID/therapy metadata.
- Unsigned `build-for-testing` succeeded for the application and extensions on iOS Simulator ARM64 and x86_64.

Base: `JohanDegraeve/xdripswift:develop` at `ba37f261352eedfb7f518c4a38e2266acb0f95e9`.
Head: `d3xr/xdripswift:fix/widget-runtime-data`.

Compare: https://github.com/JohanDegraeve/xdripswift/compare/develop...d3xr:fix/widget-runtime-data

This draft does not change CGM protocols, calibration, application branding, signing, or Core Data models.

Opened: https://github.com/JohanDegraeve/xdripswift/pull/785
