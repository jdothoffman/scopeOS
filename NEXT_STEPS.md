# Next steps

Where scopeOS stands and what to pick up next. Most features have only been tested against the built-in simulator; the hardware checks below come first.

## 1. Check on the real hardware

These need the telescope, and they decide whether some code needs adjusting. Use the smallest steps, keep the Stop button (Esc) at hand, and keep the traffic log open: it shows every byte sent and received.

**Mount (WiFi module)**
- [x] **Left/right direction.** Checked on the scope: "Right" (larger azimuth motor angle) turns the right way.
- [x] **Up/down direction.** Checked on the scope: "Up" (larger altitude motor angle) goes up.
- [x] **Altitude reading.** Was 23° off: the motors count from their power-on position. Switched on level and pointing north, the readings are 0°/0° (checked). scopeOS now has **Calibrate** (level / north / Polaris) for when the mount wasn't switched on that way.
- [ ] **Calibration on the scope.** Level the tube, click Calibrate › Tube is level now, and check the altitude reads 0°; at night, try Centred on Polaris.
- [x] **Crossing the motors' zero.** Checked: switched on at home (motors at 0°), Fine steps Left 0.1° and Down 0.1° each moved a tenth of a degree, so the motors take the short way across 0°.
- [x] **Hold-to-move.** Checked: holds keep moving in all four directions. They paused between steps (each sent once the last had finished); now the next step goes out shortly before the current one ends, and holds are capped at 15 s.
- [x] **Fast Go to (tried, reverted).** 2026-10-09: Go to with the motor's fast GoTo (`0x02`) and an end point re-sent every 150 ms went wrong on the mount (log `scopeOS 2026-10-09 16.33.32.log`): from altitude −1.17° (just below the motor's zero) a fast GoTo to +0.33° drove the motor *down*; targets re-sent above it didn't turn it round, and it ran to −5.5° until the altitude band refused the next step; switching to the slow GoTo while moving fast overshot by 1.2°/0.8° and didn't come back. Reverted to slow steps waited for one by one. If a faster Go to is tried again: never cross the motors' zero with the fast GoTo, never re-send a target while moving fast, and finish with a separate slow GoTo from rest.
- [ ] **Smooth holds on the scope.** Check a hold no longer pauses every 5° (1.5° up/down): the motor should take each new GoTo target without stopping. If it still stops briefly, try a larger lead (`HeldMove.lead`).
- [x] **Return to home.** Checked from a short way off and after longer holds: it arrives back on the marks and shows "At the home position." Not yet specifically watched: Stop cancelling it partway.
- [x] **Go to Polaris missed badly (resolved).** The 2026-10-09 morning miss (near M31/Mirach) ran on the old phone-compass calibration. After recalibrating (settings reset by the rename), Go to Polaris was on the money the same day, and the sky map matched the real sky. A daytime landmark calibration is still a possible extra, but not needed.
- [x] **Sky map against the real sky.** Checked 2026-10-09: the crosshair sat on Lynx, confirmed with a separate star-finder app on a phone resting on the scope. The home calibration and the sky maths agree with the real sky. Still worth a check at night on a bright star at high magnification.
- [x] **Go to.** Checked 2026-10-09: Go to Polaris lands on it. Still to try: a bright star well away from Polaris (Vega, Arcturus, Capella), and whether it stays put afterwards (the mount tracking) or drifts.
- [ ] **Tracking after moves.** Does tracking continue after a nudge, hold or Stop? If not, re-enable it from the hand controller (or add a fix).
- [ ] **Stop during a hand-controller GoTo.** Does the scope stay stopped, or does the hand controller resume with a slow final approach? If it resumes, make Stop hold the motors for a few seconds.

**Focus motor (Celestron, on the AUX bus)**
- [x] **Calibrated limits.** Checked: the real focus motor reports its calibrated range (2,421–45,990) with the limits command (`0x2C`).
- [ ] **Focus moves.** A ±10 step should move the position by 10. If nothing happens, check the GoTo command (`0x02`) in the log.
- [ ] **Direction.** "+" means higher position numbers; note whether that is focusing in or out.

**iPhone and iPad** (so far only in the iOS Simulator)
- [ ] **Find** on the iPhone's WiFi (home or Starlink network) finds the module; connecting on the module's own network at 1.2.3.4.
- [ ] **Holds by touch.** Holding an arrow moves until release. Pull down Control Center mid-hold: the move must stop. Let the finger drift on the arrow: if the page scrolls instead, the move stops (safe, but say if it's annoying).
- [ ] **Leaving mid-move.** Press Home during a Return to home: it stops, the log shows "Paused", and coming back reconnects with the calibration still applied and doesn't ask about the home marks again.
- [ ] **Screen stays on** while connected; locks normally after Disconnect.
- [ ] **STOP bar** reachable on every tab, in portrait and landscape, on iPhone and iPad.
- [ ] **Sky map** panning and pinching inside the scrolling page.
- [ ] **GPS location** on the telescope's WiFi with no internet.

**Camera (SVBONY SV205)**
- [ ] **First recording from the app.** Record 30 s at YUVS 640×480, then check the SER file opens in a stacker and the notes `.txt` looks right.
- [ ] **Crop or shrink?** Compare the view at 3264×2160 and 1280×720 on a distant daytime target. If the smaller mode shows the same view, only less sharp, record planets at full resolution instead.

## 2. Features to build next

Also discussed:

- **Send location and time to the hand controller** over USB (official `W` / `H` commands, read back with `w` / `h`), before StarSense alignment.
- **Before making the repo public:** a tested-on-hardware status table, GitHub Actions running the tests. (License, safety notice, commit email and test location: done.)


In rough order of value:

1. **Keep a Go to target centred.** scopeOS doesn't track: after a Go to, re-send small bounded GoTos every few seconds to follow the star (same steps and Sun checks). Then planets and the Moon in the Go to list (they need their own position calculations).
1. ~~**Focus aid.**~~ Built: live sharpness, % of best, trend, and Go to best. Still to check on a real target (a distant object by day, a bright star or planet at night). **Next: automatic focus** that steps through focus and settles on the peak, bounded by the focus motor's calibrated range.
2. **Region of interest.** Record only a box around the planet: smaller files, faster stacking.
3. **Keep the planet centred.** Use the camera image to nudge the mount automatically (within all the existing motion limits).
4. **First-light hardware check screen.** A guided version of section 1 inside the app.
5. **Tonight planner.** Planets, Moon and showpiece objects with altitude and rise/set times, plus darkness times and cloud cover.
6. **Moon on the sky chart**, with phase.
7. **Link-loss alert.** Sound and banner if the WiFi connection drops, especially during a move.
8. ~~**Clear message when SkyPortal holds the WiFi module**~~ Done: says nothing answered and asks whether SkyPortal is connected; retries back off from 3 s to 30 s.

Bigger projects, discussed but not started:

- **GoTo over USB** (hand-controller protocol) with safeguards: no GoTo while the Sun is up, 30° Sun keep-out, 0°–75° altitude, alignment required, confirmation dialog, its own enable switch.
- **scopeOS's own alignment** (2–3 stars), giving RA/Dec and GoTo over WiFi.
- **SkyPortal recording relay**, to see what StarSense Auto Align sends before deciding whether to support it.
- **Dedicated planetary camera support** (ZWO / Player One SDKs) if the camera is upgraded; FireCapture already handles those on the Mac.

## 3. Housekeeping

- ~~**Tests for the app's own logic.**~~ Done: route planning, cable tracking and connection messages are tested in ScopeKit, and `AppTests` runs `MonitorModel` against the simulator (holds, enable switches, daylight lock, Return to home, Go to refusals) with `xcodebuild test -scheme ScopeOS`. Not yet covered: the camera model (focus history, recording notes, disk space).
- **Night vision check.** Confirm system controls (buttons, switches, text fields) also turn red; the camera preview has its own red filter.
- **An install script** that builds a Release copy into /Applications. (App icon: done; redraw it with `swift scripts/make-icon.swift App/Assets.xcassets/AppIcon.appiconset`.)
- **CLAUDE.md** recording the safety rules: every command checked byte for byte against an exact allowlist immediately before it is written; moves always bounded (a GoTo to a nearby target, never a free-running rate); Stop always available; safety switches reset on launch and disconnect.

## Handy commands

```sh
cd Packages/ScopeKit
swift test                      # all library tests
swift run scopesim              # simulated mount (with focus motor) on 127.0.0.1:2000/2001
swift run scopeos-cli wifi --verbose   # terminal monitor, prints every byte
swift run scopecap controls     # camera controls and a write test
```
