#!/bin/bash
set -uo pipefail
cd "$(dirname "$0")"
APP="$PWD/Glass Ripples.app"
EXECUTABLE="$APP/Contents/MacOS/GlassRipples"
LOG="$PWD/Launch.log"
if [[ ! -x "$EXECUTABLE" ]]; then
    echo "The compiled app is missing. Run build.command first."
    read -r -p "Press Return to close. "
    exit 1
fi
echo "Restarting Glass Ripples through macOS."
echo "Look for the water-waves icon in the menu bar and the first-launch dialog."
echo "Version 0.4: tap for ripples, drag a finger to leave a water wake."
echo "Toggle: Control–Option–Command–R"
echo "Errors are saved in Launch.log in this folder."
echo
/usr/bin/killall GlassRipples >/dev/null 2>&1 || true
/usr/bin/open -n -W --stderr "$LOG" "$APP"
STATUS=$?
echo
echo "Glass Ripples exited with status $STATUS."
if [[ "$STATUS" -ne 0 ]]; then
    echo "Leave this window open so the launch error can be inspected."
    read -r -p "Press Return to close. "
fi
exit "$STATUS"
