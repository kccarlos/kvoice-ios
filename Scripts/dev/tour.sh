#!/usr/bin/env bash
# Screenshot tour of every screen (light, dark, largest text) on the pinned
# simulator or the USB test iPhone. Leaves PNGs in
# $KVOICE_DEV_ROOT/evidence/<run-name>/<light|dark|largetext>/.
#
#   Scripts/dev/tour.sh sim|device <run-name>
#
# Machine settings come from the environment or Config/Local.xcconfig
# (KEY = value lines): KVOICE_DEV_ROOT, KVOICE_SIM_UDID, and for the device
# KVOICE_DEVICE_UDID and KVOICE_LOCK_DIR.
set -euo pipefail
cd "$(dirname "$0")/../.."

target=${1:-}; run=${2:-}
[[ $target == sim || $target == device ]] && [[ -n $run ]] || { echo "usage: $0 sim|device <run-name>" >&2; exit 2; }

setting() {  # environment first, then Config/Local.xcconfig
  local value=${!1:-}
  [[ -n $value ]] || value=$(sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" Config/Local.xcconfig 2>/dev/null | tail -1)
  [[ -n $value ]] || { echo "set $1 (environment or Config/Local.xcconfig)" >&2; exit 2; }
  printf '%s' "$value"
}

root=$(setting KVOICE_DEV_ROOT)
out="$root/evidence/$run"
result="$out/tour.xcresult"
[[ ! -e $result ]] || { echo "$result exists; pick another run name" >&2; exit 2; }
mkdir -p "$out"
Scripts/generate.sh

args=(-project KVoice.xcodeproj -scheme KVoiceUITour -parallel-testing-enabled NO -resultBundlePath "$result")
if [[ $target == sim ]]; then
  udid=$(setting KVOICE_SIM_UDID)
  xcrun simctl boot "$udid" 2>/dev/null || true
  trap 'xcrun simctl shutdown "$udid" 2>/dev/null || true' EXIT
  args+=(-destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$root/dd-tour-sim" CODE_SIGNING_ALLOWED=NO)
else
  udid=$(setting KVOICE_DEVICE_UDID)
  lock="$(setting KVOICE_LOCK_DIR)/$udid.lock"
  until mkdir "$lock" 2>/dev/null; do
    if [[ -d $lock ]] && (( $(date +%s) - $(stat -f %m "$lock") > 45 * 60 )); then
      echo "removing stale device lock $lock" >&2; rmdir "$lock" 2>/dev/null || true; continue
    fi
    echo "device busy ($lock); retrying in 20 s" >&2; sleep 20
  done
  trap 'rmdir "$lock"' EXIT
  args+=(-destination "id=$udid" -derivedDataPath "$root/dd-tour-device"
         -allowProvisioningUpdates -allowProvisioningDeviceRegistration)
fi

status=0
xcodebuild test "${args[@]}" > "$out/xcodebuild.log" 2>&1 || status=$?
tail -5 "$out/xcodebuild.log"

# Export the screenshots, then sort them into one folder per variant.
xcrun xcresulttool export attachments --path "$result" --output-path "$out/attachments" >/dev/null
python3 -I - "$out" <<'PY'
import json, pathlib, re, shutil, sys
out = pathlib.Path(sys.argv[1]); src = out / "attachments"
variants = {"test1Light": "light", "test2Dark": "dark", "test3LargeText": "largetext"}
count = 0
for test in json.loads((src / "manifest.json").read_text()):
    variant = next((v for k, v in variants.items() if k in test["testIdentifier"]), None)
    for item in test.get("attachments", []) if variant else []:
        name = re.sub(r"_\d+_[0-9A-F-]{36}(?=\.png$)", "", item["suggestedHumanReadableName"])
        if not re.fullmatch(r"\d\d-[\w-]+\.png", name):
            continue  # failure snapshots, recordings: they stay in tour.xcresult
        (out / variant).mkdir(exist_ok=True)
        shutil.copy(src / item["exportedFileName"], out / variant / name); count += 1
shutil.rmtree(src)
print(f"{count} screenshots in {out}")
PY
exit $status
