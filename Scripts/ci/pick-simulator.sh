#!/usr/bin/env bash
# Print an xcodebuild destination for an available iPhone on the newest iOS runtime.
set -euo pipefail
udid=$(xcrun simctl list devices available -j | python3 -c '
import json, re, sys
data = json.load(sys.stdin)["devices"]
# Keys look like ...SimRuntime.iOS-27-0, sometimes with a suffix after the version.
def version(r):
    m = re.search(r"iOS-(\d+(?:-\d+)*)", r)
    return [int(x) for x in m.group(1).split("-")] if m else []
runtimes = sorted((r for r in data if "iOS-" in r), key=version)
for r in reversed(runtimes):
    phones = [d for d in data[r] if d["name"].startswith("iPhone")]
    if phones:
        print(phones[-1]["udid"]); break
')
[[ -n "$udid" ]] || { echo "no iPhone simulator found" >&2; exit 1; }
echo "platform=iOS Simulator,id=$udid"
