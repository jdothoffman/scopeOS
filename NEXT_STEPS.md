# Next steps

Where scopeOS stands and what to pick up next. The hardware checks are done (one camera comparison is left), so the features below are next.

## 1. Hardware checks

Every check below has passed on the real equipment (NexStar 6SE with the SkyPortal WiFi module, the Celestron focus motor, the SVBONY SV205, an iPhone and an iPad), except the one still open.

**Still to check**
- [ ] **Camera: crop or shrink?** Compare the view at 3264×2160 and 1280×720 on a distant daytime target. If the smaller mode shows the same view, only less sharp, record planets at full resolution instead.

**What the checks found** (worth knowing when changing the code)
- **Directions:** "Right" (larger azimuth motor angle) turns right; "Up" (larger altitude motor angle) goes up. The motors take the short way across their zero.
- **Readings:** the motors count from their power-on position, so they read 0°/0° only when switched on level and pointing north; otherwise use Calibrate or the home position. Both calibration and the home position check out, and Go to and the sky map agree with the real sky.
- **Tracking:** the mount keeps tracking after a nudge, hold or Stop, and a Go to target stays put afterwards. Stop during a hand-controller GoTo stays stopped.
- **Focus motor:** reports its calibrated range (2,421–45,990) with `0x2C`; a ±10 step moves the position by 10; **"+" (higher numbers) focuses out**. The focus aid peaks where the image looks sharpest, and Go to best returns there.
- **Fast Go to, first try (reverted).** 2026-10-09: a fast GoTo (`0x02`) with its end point re-sent every 150 ms went wrong (log `scopeOS 2026-10-09 16.33.32.log`): from altitude −1.17° (just below the motor's zero) a fast GoTo to +0.33° drove the motor *down*; re-sent targets didn't turn it round, and it ran to −5.5° until the altitude band refused the next step; switching to the slow GoTo while moving fast overshot by 1.2°/0.8°. The second design (one fast GoTo per stretch, from rest, never re-sent, half a degree short, both ends at least 1° clear of the motor's zero, slow steps across zero and for the final approach) passed every check: short moves, up/down, from home, across azimuth zero, Stop mid-slew, and Return to home unwinding the cable. Keep those rules if Go to is changed again.
- **Holds** run smoothly, without pausing between steps.
- **Go to the Moon, a planet and the Sun** (Solar mode, with the filter checklist and the record file) land on target, and End Solar Mode brings the keep-out back.
- **iPhone and iPad:** Find, holds by touch (Control Center mid-hold stops the move), leaving mid-move, screen staying on, the STOP bar, the sky map gestures and GPS without internet all behave as designed.
- **Camera:** recording from the app gives a SER file a stacker opens, with the right notes `.txt`; ⌘Q mid-recording leaves a complete `.ser` and its notes.

## 2. Features to build next

In rough order of value:

1. **Automatic focus.** Step through focus and settle on the sharpest point, using the focus aid's sharpness and bounded by the focus motor's calibrated range. The focus motor's moves and direction are now checked ("+" focuses out).
2. **Keep a Go to target centred.** After a Go to (star, planet or Moon), re-send small bounded GoTos every few seconds to follow it, with the same steps, altitude band and Sun checks, ending on Stop, any manual move, Disconnect, or leaving the screen (iOS). Lower priority now: the mount was seen to keep tracking by itself after Go to and manual moves, so this matters only if it's switched on without tracking.
3. **Link-loss alert.** Sound and banner if the WiFi connection drops, especially during a move.
4. **Region of interest.** Record only a box around the planet: smaller files, faster stacking.
5. **Keep the planet centred.** Use the camera image to nudge the mount automatically (within all the existing motion limits). Builds on 2 and 4.
6. **First-light hardware check screen.** A guided version of the hardware checks inside the app, for other people's mounts.
7. **Moon phase on the sky map.** The Moon is drawn as a plain disc; Tonight already knows how much of it is lit.
8. **Cloud cover in Tonight.** Tonight has the targets, their best times and darkness, but no weather.
9. **Snapshot button** (#24) and **quick stack** (#25).
10. **Send location and time to the hand controller** over USB (official `W` / `H` commands, read back with `w` / `h`), before StarSense alignment.

Bigger projects, discussed but not started:

- **GoTo over USB** (hand-controller protocol) with safeguards: no GoTo while the Sun is up, 30° Sun keep-out, 0°–75° altitude, alignment required, confirmation dialog, its own enable switch.
- **scopeOS's own alignment** (2–3 stars), giving RA/Dec and GoTo over WiFi.
- **SkyPortal recording relay**, to see what StarSense Auto Align sends before deciding whether to support it.
- **Telescope camera on iPad** (#36).
- **Dedicated planetary camera support** (ZWO / Player One SDKs) if the camera is upgraded; FireCapture already handles those on the Mac.

Already built (kept here so they aren't proposed again): the focus aid (sharpness, % of best, trend, Go to best), planets and the Moon in Go to, the Tonight planner, the Moon and planets on the sky map, Solar mode with the filter checklist, slewing Go to and Return to home, the iPhone and iPad app, the simulated mount and camera, the Setup tab finding the WiFi module by itself, showing what the home position rests on (true north, level, Polaris), and the SkyPortal message (nothing answered; retries back off from 3 s to 30 s).

## 3. Housekeeping

- **Setup tab fixes:** the tab bar shows ⌘3 for Setup but it's ⌘4 (#44); the tab overflows the window at its minimum size (#43).
- **Tests for the camera model** (focus history, recording notes, disk space). Route planning, cable tracking and connection messages are tested in ScopeKit, and `AppTests` runs `MonitorModel` against the simulator with `xcodebuild test -scheme ScopeOS`.
- **Night vision check.** Confirm system controls (buttons, switches, text fields) also turn red; the camera preview has its own red filter.
- **CLAUDE.md** recording the safety rules: every command checked byte for byte against an exact allowlist immediately before it is written; moves always bounded (a GoTo to a nearby target, never a free-running rate); Stop always available; safety switches reset on launch and disconnect.

## Handy commands

```sh
cd Packages/ScopeKit
swift test                      # all library tests
swift run scopesim              # simulated mount (with focus motor) on 127.0.0.1:2000/2001
swift run scopeos-cli wifi --verbose   # terminal monitor, prints every byte
swift run scopecap controls     # camera controls and a write test
```

From the repo root, for the app:

```sh
scripts/run.sh                  # debug build (simulator, DEBUG badge, movement switches)
scripts/run.sh release          # release build, launched from build.noindex
scripts/run.sh install          # release build copied to /Applications (run again to update it)
swift scripts/make-icon.swift App/Assets.xcassets/AppIcon.appiconset   # redraw the app icon
```
