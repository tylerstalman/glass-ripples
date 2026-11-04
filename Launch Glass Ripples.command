#!/bin/bash
set -uo pipefail
cd "$(dirname "$0")"
APP="$PWD/Glass Ripples.app"
EXECUTABLE="$APP/Contents/MacOS/GlassRipples"
if [[ ! -x "$EXECUTABLE" ]]; then
    echo "The compiled app is missing. Run build.command first."
    read -r -p "Press Return to close. "
    exit 1
fi
echo "Restarting Glass Ripples directly in your desktop session."
echo "Look for the water-waves icon in the menu bar and the first-launch dialog."
echo "Version 0.4.2: tap for ripples, drag a finger to leave a water wake."
echo "Toggle: Control–Option–Command–R"
echo "Keep this Terminal window open while the app runs."
echo "Diagnostics are saved in the temporary GlassRipples.log file."
echo
/usr/bin/killall GlassRipples >/dev/null 2>&1 || true
"$EXECUTABLE"
STATUS=$?
echo
echo "Glass Ripples exited with status $STATUS."
if [[ "$STATUS" -ne 0 ]]; then
    echo "Leave this window open so the launch error can be inspected."
    read -r -p "Press Return to close. "
fi
exit "$STATUS"
