#!/bin/bash
set -euo pipefail

APP_PATH="$1"
OUTPUT_DIR="$2"
BUNDLE_ID="au.h-v.in.sync"
mkdir -p "$OUTPUT_DIR"

# An iOS runtime is required to boot the devices, even if the simulator SDK is installed.
available_runtime() {
  xcrun simctl list runtimes available -j | python3 -c '
import json
import sys

runtimes = [
    runtime for runtime in json.load(sys.stdin)["runtimes"]
    if runtime["isAvailable"] and ".iOS-" in runtime["identifier"]
]
if runtimes:
    runtime = max(runtimes, key=lambda item: tuple(map(int, item["version"].split("."))))
    print(runtime["identifier"])
'
}

RUNTIME="$(available_runtime)"
if [[ -z "$RUNTIME" ]]; then
  xcodebuild -downloadPlatform iOS
  RUNTIME="$(available_runtime)"
fi
if [[ -z "$RUNTIME" ]]; then
  echo "No available iOS simulator runtime." >&2
  exit 1
fi

DEVICE_ID=""
cleanup() {
  if [[ -n "$DEVICE_ID" ]]; then
    xcrun simctl shutdown "$DEVICE_ID" >/dev/null 2>&1 || true
    xcrun simctl delete "$DEVICE_ID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

capture() {
  local model="$1" device_type="$2" width="$3" height="$4" prefix="$5"
  local scene filename screenshot metadata actual_format actual_width actual_height
  local scenes=(reference-time reference-frames reference-colours measure calibration)

  DEVICE_ID="$(xcrun simctl create "$model App Store Capture" "$device_type" "$RUNTIME")"
  # Suppress the first-boot Apple Intelligence readiness banner.
  xcrun simctl list devices -j | python3 -c '
import datetime
import json
import pathlib
import plistlib
import sys

device = next(
    device for devices in json.load(sys.stdin)["devices"].values()
    for device in devices if device["udid"] == sys.argv[1]
)
prefs = pathlib.Path(device["dataPath"]) / "Library" / "Preferences"
prefs.mkdir(parents=True, exist_ok=True)
with (prefs / "com.apple.generativeexperiences.corefollowup.plist").open("wb") as file:
    plistlib.dump({"DateOfLastAppleIntelligenceReadinessCFU": datetime.datetime(2020, 1, 1)}, file)
' "$DEVICE_ID"
  xcrun simctl boot "$DEVICE_ID"
  xcrun simctl bootstatus "$DEVICE_ID" -b
  xcrun simctl status_bar "$DEVICE_ID" override --time "9:41" \
    --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --batteryState discharging --batteryLevel 100
  xcrun simctl install "$DEVICE_ID" "$APP_PATH"
  for scene in "${!scenes[@]}"; do
    filename="$(printf '%02d-%s' "$((scene + 1))" "${scenes[$scene]}")"
    screenshot="$OUTPUT_DIR/In.Sync-$prefix-$filename.jpg"
    SIMCTL_CHILD_INSYNC_SCREENSHOT="${scenes[$scene]}" \
      xcrun simctl launch --terminate-running-process "$DEVICE_ID" "$BUNDLE_ID"
    sleep 5
    xcrun simctl io "$DEVICE_ID" screenshot --type=jpeg "$screenshot"

    metadata="$(sips -g format -g pixelWidth -g pixelHeight "$screenshot")"
    actual_format="$(awk '/format:/ {print $2}' <<< "$metadata")"
    actual_width="$(awk '/pixelWidth:/ {print $2}' <<< "$metadata")"
    actual_height="$(awk '/pixelHeight:/ {print $2}' <<< "$metadata")"
    if [[ "$actual_format" != jpeg || "$actual_width" != "$width" || "$actual_height" != "$height" ]]; then
      echo "$screenshot: expected a ${width} x ${height} JPEG, got $metadata" >&2
      exit 1
    fi
    echo "$screenshot: verified ${width} x ${height}"
  done

  cleanup
  DEVICE_ID=""
}

capture "iPhone 17 Pro" "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro" \
  1206 2622 "iPhone-6.3-inch"
IPAD_TYPE="$(xcrun simctl list devicetypes -j | python3 -c '
import json
import re
import sys

devices = json.load(sys.stdin)["devicetypes"]
candidates = [
    device for device in devices
    if re.search(r"iPad Pro.*13[ -]inch", device["name"], re.IGNORECASE)
]
if not candidates:
    raise SystemExit("No 13-inch iPad Pro simulator device type is installed.")
print(next(
    (device["identifier"] for device in candidates if "M4" in device["name"]),
    candidates[0]["identifier"],
))
')"
capture "iPad Pro 13-inch" "$IPAD_TYPE" \
  2064 2752 "iPad-13-inch"
