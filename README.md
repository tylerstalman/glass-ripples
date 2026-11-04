# Glass Ripples

A macOS menu bar app that refracts the desktop beneath your fingertips. Tap for liquid glass ripples or drag one or more fingers to leave fading water wakes.

## Install

Requires Apple Silicon, macOS 14+, Apple's Command Line Tools, and a compatible built-in Apple touchscreen. The sensor decoder supports the Apple Kiwi panel's 62 × 94 capacitance grid. Trackpads, external touchscreens, and Sidecar are unsupported.

Download this repository with **Code → Download ZIP**, unzip it, and double-click **build.command**. If Command Line Tools are missing, finish Apple's installer and run the script again. Full Xcode and a paid developer account are unnecessary.

Or build from Terminal:

```sh
git clone https://github.com/tylerstalman/glass-ripples.git
cd glass-ripples
./build.command
```

Allow **Glass Ripples** in **System Settings → Privacy & Security → Screen & System Audio Recording**, then reopen it. Leave the screen untouched for two seconds for an idle sensor reading.

The app is locally ad-hoc signed. Rebuilding can require removing the old Screen Recording entry and adding the rebuilt app again.

## Use

- Tap the built-in display for an expanding ripple.
- Drag fingers to leave short refractive wakes.
- **Control–Option–Command–R** toggles the effect.
- The water-waves menu includes a test ripple and Quit.
- **Launch Glass Ripples.command** restarts the app and saves errors in local **Launch.log**.

Fingertips that meet or cross can temporarily merge into one detected patch. This experimental decoder targets a specific panel, and macOS updates may change its report format.

## Implementation

ScreenCaptureKit supplies desktop pixels while an effect is active. Metal bends those pixels and samples red, green, and blue at slightly different offsets for chromatic dispersion. The overlay lets underlying apps receive input.

Capture and drawing stop when effects expire. Movement emits at most 30 updates per second per finger, and at most 24 ripple or wake segments are drawn at once.

A nonexclusive IOKit listener reads reports only from the built-in Apple Kiwi touchscreen. The decoder rejects calibration scans, finds separate fingertip patches, and matches them between frames. Sensor data and screen frames stay in memory. Nothing is transmitted.

For visual adjustments, edit **Sources/Ripple.metal** beside the app and restart. The bundled shader is used if that file is absent.

## Development

```sh
./build.command --no-open
./Tests/run.sh
```

The hardware-independent suite covers calibration rejection, malformed reports, stationary contacts, drag throttling, separate finger IDs, lifting/rejoining, and timestamp rollover. Real touchscreen behavior and visuals require a physical test.

Apple resources:

- [Meet Liquid Glass](https://developer.apple.com/videos/play/wwdc2025/219/)
- [Meet ScreenCaptureKit](https://developer.apple.com/videos/play/wwdc2022/10156/)
- [IOHIDManager](https://developer.apple.com/documentation/iokit/iohidmanager_h)

## License

MIT.
