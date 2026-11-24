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
  local model="$1" device_type="$2" width="$3" height="$4" filename="$5"
  local screenshot="$OUTPUT_DIR/$filename"

  DEVICE_ID="$(xcrun simctl create "$model App Store Capture" "$device_type" "$RUNTIME")"
  xcrun simctl boot "$DEVICE_ID"
  xcrun simctl bootstatus "$DEVICE_ID" -b
  xcrun simctl status_bar "$DEVICE_ID" override --time "9:41" \
    --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --batteryState discharging --batteryLevel 100
  xcrun simctl install "$DEVICE_ID" "$APP_PATH"
  xcrun simctl launch "$DEVICE_ID" "$BUNDLE_ID"
  sleep 5
  xcrun simctl io "$DEVICE_ID" screenshot "$screenshot"

  python3 - "$screenshot" "$width" "$height" <<'PY'
import struct
import sys

path, width, height = sys.argv[1:]
with open(path, "rb") as screenshot:
    header = screenshot.read(24)
if header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
    raise SystemExit(f"{path}: expected a PNG screenshot")
actual = struct.unpack(">II", header[16:24])
if actual != (int(width), int(height)):
    raise SystemExit(f"{path}: expected {width} x {height}, got {actual}")
print(f"{path}: verified {width} x {height}")
PY

  cleanup
  DEVICE_ID=""
}

capture "iPhone 17 Pro Max" "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max" \
  1320 2868 "In.Sync-iPhone-6.9-inch.png"
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
  2064 2752 "In.Sync-iPad-13-inch.png"
