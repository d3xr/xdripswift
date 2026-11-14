#!/bin/bash
set -euo pipefail

XDRIP_REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XDRIP_OUTPUT_DIR="${XDRIP_OUTPUT_DIR:-$XDRIP_REPO_DIR/.local-build}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p "$XDRIP_OUTPUT_DIR"
XDRIP_OUTPUT_DIR="$(cd "$XDRIP_OUTPUT_DIR" && pwd)"
cd "$XDRIP_REPO_DIR"
XDRIP_BUILD_ARGS=(
  -workspace xdrip.xcworkspace -scheme xdrip -configuration Debug
  -destination "${XDRIP_DESTINATION:-generic/platform=iOS}"
  -derivedDataPath "$XDRIP_OUTPUT_DIR/DerivedData"
  "SYMROOT=$XDRIP_OUTPUT_DIR/DerivedData/Build/Products"
  "OBJROOT=$XDRIP_OUTPUT_DIR/DerivedData/Build/Intermediates.noindex"
  'CONFIGURATION_BUILD_DIR=$(SYMROOT)/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)'
)
xcodebuild "${XDRIP_BUILD_ARGS[@]}" -allowProvisioningUpdates build > "$XDRIP_OUTPUT_DIR/build.log" 2>&1
xcodebuild "${XDRIP_BUILD_ARGS[@]}" -showBuildSettings -json \
  > "$XDRIP_OUTPUT_DIR/build-settings.json" 2> "$XDRIP_OUTPUT_DIR/build-settings.log"
XDRIP_APP_PATH="$(python3 - "$XDRIP_OUTPUT_DIR/build-settings.json" <<'PYTHON'
import json, pathlib, sys
settings = json.loads(pathlib.Path(sys.argv[1]).read_text())
app = next(item['buildSettings'] for item in settings if item['target'] == 'xdrip')
path = pathlib.Path(app['TARGET_BUILD_DIR']) / app['FULL_PRODUCT_NAME']
if not path.is_dir():
    raise SystemExit('Built application not found: ' + str(path))
print(path)
PYTHON
)"
XDRIP_PACKAGE_DIR="$(mktemp -d "$XDRIP_OUTPUT_DIR/package.XXXXXX")"
ditto "$XDRIP_APP_PATH" "$XDRIP_PACKAGE_DIR/xdrip.app"
codesign --verify --deep --strict "$XDRIP_PACKAGE_DIR/xdrip.app"
printf '%s\n' "$XDRIP_PACKAGE_DIR/xdrip.app"
