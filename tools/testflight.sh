#!/bin/bash
# Builds the app for release and uploads it to TestFlight.
#
#   ./tools/testflight.sh                 next build number, archive, upload
#   ./tools/testflight.sh --same-build    keep the build number in creator/app.json
#   ./tools/testflight.sh --archive-only  archive but don't upload (implies --same-build)
#
# Needs apple.teamId in creator/app.json, Xcode signed in to that team, and
# the app's record already created in App Store Connect with your bundle id.
# No API key: Xcode's signed-in account does the signing and the upload.
set -euo pipefail
cd "$(dirname "$0")/.."

bump=1
upload=1
for arg in "$@"; do
  case "$arg" in
    --same-build) bump=0 ;;
    --archive-only) bump=0; upload=0 ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

if [ "$bump" = 1 ]; then
  python3 - <<'EOF'
import json
path = "creator/app.json"
with open(path, encoding="utf-8") as f:
    config = json.load(f)
app = config.setdefault("app", {})
app["build"] = int(app.get("build", 0)) + 1
with open(path, "w", encoding="utf-8") as f:
    json.dump(config, f, indent=2, ensure_ascii=False)
    f.write("\n")
print(f"Build number is now {app['build']}.")
EOF
fi

./configure

archive=build/CreatorApp.xcarchive
rm -rf "$archive"
xcodebuild -project CreatorApp.xcodeproj -scheme CreatorApp -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath build/DerivedData \
  -archivePath "$archive" -allowProvisioningUpdates archive

if [ "$upload" = 1 ]; then
  xcodebuild -exportArchive -archivePath "$archive" \
    -exportOptionsPlist Generated/ExportOptions-upload.plist -allowProvisioningUpdates
  echo "Uploaded. It shows up in TestFlight after Apple finishes processing it (usually a few minutes)."
else
  echo "Archived to $archive (not uploaded)."
fi
