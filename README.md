# scopeOS

**Telescope control and capture, made for the Mac**, for Celestron NexStar mounts. Built for a NexStar 6SE with StarSense and the SkyPortal WiFi module. It shows where the telescope is pointing, whether it is slewing, alignment, tracking mode, distance from the Sun, and connected devices; moves the mount (holds, Return to home, Go to a bright star), drives a Celestron focus motor with a focus aid, and records the telescope camera to SER files for stacking. An independent project: not made or endorsed by Celestron (see [Safety and disclaimer](#safety-and-disclaimer)).

**Control is deliberately limited.** Apart from status queries, scopeOS sends only these commands:

- **Stop Telescope** (red button, or Esc) halts any slew, GoTo or nudge in progress.
- **Control panel** (WiFi module only): hold an arrow to move, release to stop. Moves are refused while the mount is already moving. In debug builds movement has to be switched on first (up/down has a second switch) and switches itself off on disconnect; release builds hide those switches and keep movement on.
  - **Steps with fixed end points:** a hold is sent as a series of slow GoTos, each to a point at most 5° away (left/right) or 1.5° away (up/down). The next step goes out shortly before the current one ends, so the scope moves smoothly, without pausing. The mount stops at each end point on its own, so if the app or the WiFi connection dies mid-hold, the motor stops within one step. (Return to home and Go to wait for each step to finish before the next.)
  - **15-second limit:** a hold is stopped after 15 seconds even if the arrow is still held, so no single hold moves the scope for longer than that. Release and press again to keep going. Moving also stops if scopeOS loses focus.
  - **Fine steps:** single moves of 0.1° to 5° (left/right) or 0.1° to 1.5° (up/down).
  - **Sun lock:** no move may pass within 30° of the Sun anywhere along its path (moves that steadily back away from it are always allowed). Arrows pointing toward the Sun are greyed out. Movement needs a location set, and is locked entirely while the Sun is up unless you turn off **Lock while the Sun is up** (it turns itself back on at every launch). Over the WiFi module this uses the motor angles, so it is only as accurate as the mount's alignment.
  - **Altitude band:** up/down only works between 0° and 75° altitude (calibrated, if a calibration is set); a hold stops at the edge. If the scope is ever outside the band, moves back toward it are allowed and moves further out are refused, so it can always be brought back. There is no left/right limit, so watch the camera cable on long swings; **Return to home** unwinds it.
  - **Return to home:** drives back to the [home position](#calibrating-the-wifi-readings), altitude first and then azimuth (or the other way round if that keeps clear of the Sun), in the same steps as a hold. The whole route is checked against the Sun before it starts, and each step again on the way. Azimuth turns back the way the scope has turned since scopeOS connected, unwinding the cable (up to one turn). Needs a saved home position and a calibration; **Stop** cancels it. After you confirm the mount was switched on at its home marks, scopeOS offers to return if the scope isn't there.
  - **Go to:** points at Polaris or one of 15 bright stars, worked out from your location and the time (J2000 positions brought up to date for precession). The menu shows where each one is now; scopeOS refuses targets below the horizon, above 75° or whose route passes near the Sun, and asks before moving. It drives there like Return to home, then makes up to two short correcting moves, because the star moves on while the scope travels. How close it lands depends on the calibration: a phone-compass calibration may be a few degrees out, so Go to Polaris, centre it, then **Calibrate › Centred on Polaris** (and **Save as home position** if the session started at home). scopeOS doesn't track yet, so stars other than Polaris drift out of view unless the mount is tracking by itself.
- **Focus motor** (Celestron focus motor, WiFi module only): bounded moves inside the motor's calibrated range. See [Focus motor](#focus-motor).

Every byte is checked immediately before it is written:

- **Queries** against a list of read-only commands, each allowed only to the devices where it is read-only (`ReadOnlyGuard`).
- **Stops** against the exact stop packets (`StopCommand`).
- **Moves** (nudges, and every step of a hold, Return to home or Go to) against the motor's freshly read position, the per-axis step cap and the altitude band (`NudgeCommand`), and against the Sun rules (`MotionPolicy`: a location must be set, the daylight lock, the 30° keep-out along the path). The client checks the Sun rules itself, from both motors' fresh positions, so they apply to every caller, not just the app's controls.
- **Focus moves** against the focuser's position and calibrated range (`FocusCommand`).

Nothing else can be sent.

## Safety and disclaimer

**Never point a telescope at the Sun without a proper solar filter covering the front of the telescope.** Looking at the Sun through a telescope, even for an instant, causes permanent eye damage, and it can destroy a camera. scopeOS's Sun lock is a safeguard, not a guarantee: over the WiFi module it relies on the mount's alignment, and it cannot see what you point the telescope at by other means.

scopeOS moves real equipment. Stay with the telescope while it is connected, keep the area around it clear, and keep a hand near the power switch, especially the first time you use the movement controls. Many features have so far only been tested against the built-in simulator; see [NEXT_STEPS.md](NEXT_STEPS.md) for what has and hasn't been checked on hardware.

scopeOS is an independent project and is not affiliated with, endorsed by, or supported by Celestron, SVBONY, or any other manufacturer. Product names are trademarks of their owners. The communication protocols are based on Celestron's published hand-controller protocol and on community documentation of the AUX bus; they may change with firmware updates.

The software is provided "as is", without warranty of any kind, under the [MIT License](LICENSE). You use it at your own risk; the authors are not liable for any damage to equipment, eyesight or anything else.

## Open and run

1. Open `ScopeOS.xcodeproj` in Xcode.
2. Pick a scheme and press **Run** (⌘R). No Apple Developer account is needed; the app is signed to run locally.
   - **scopeOS** (debug): developer tools: the simulator, a DEBUG badge, and the movement enable switches.
   - **scopeOS Release**: for using the telescope: no simulator, movement always enabled, optimised build.

Or from the terminal: `scripts/run.sh` (debug) or `scripts/run.sh release`. To keep it in Applications, `scripts/run.sh install` builds the release version, copies it to /Applications and launches it; run it again after pulling changes to update the installed copy.

Tests: `swift test` in `Packages/ScopeKit` (protocol, safety and motion logic, against the built-in simulator), and **Product › Test** (⌘U) or `xcodebuild test -project ScopeOS.xcodeproj -scheme ScopeOS` for the app's own logic. Neither needs the telescope, and the app tests keep their own settings, so they never touch yours. To check the layout without the telescope, `TEST_RUNNER_SCOPEOS_SNAPSHOTS=/some/folder xcodebuild test -project ScopeOS.xcodeproj -scheme ScopeOS -only-testing:ScopeOSTests/SnapshotTests` renders every tab, at the smallest window size and at 1440×900, to PNGs in that folder.

The window has four tabs (⌘1–⌘4): **Telescope** (pointing, status, sky chart, control pad, focus), **Sky** (a star map that follows the telescope, see [Sky map](#sky-map)), **Camera** (preview, histogram, camera controls and recording, with the control pad and focus beside it for centring and focusing), and **Setup** (connection and Find, location, devices, traffic log). The header, with the clocks, night vision, link status, **STOP** and Connect, stays visible on every tab. The link status turns amber ("No data for N s") if no reading has arrived for more than 5 seconds while connected, a sign the connection is failing before it errors out; hover over it for the age of the last reading. **⌘R** starts and stops a recording from any tab (Camera menu).

The first time it connects over WiFi, macOS asks whether scopeOS may find devices on your local network. Click **Allow**.

## Focus motor

With a Celestron focus motor on the AUX bus and the WiFi connection, the Focus panel shows the focuser's position within its calibrated range and moves it with step buttons (10 to 1,000 steps) or press-and-hold (up to 5 seconds). Every move is a GoTo to a target inside the calibrated range, at most a fifth of the range away, so the focuser can't be driven into its end stops and stops on its own even if the connection drops. If the motor hasn't been calibrated (from the hand controller or SkyPortal), focusing stays locked. Stopping a focus move stops only the focuser; **Stop Telescope** stops everything.

## Calibrating the WiFi readings

Over the WiFi module, azimuth and altitude come from the motors, which only count from wherever the telescope was when the mount was switched on. **Switch the mount on with the tube level and pointing north** and the readings are real sky directions. Otherwise use **Calibrate** in the Pointing panel:

- **Tube is level now:** check with a spirit level or the iPhone's Measure app (Level).
- **Pointing true north now:** use true north (iPhone Compass, with Use True North on), holding the phone away from the metal tube.
- **Centred on Polaris:** at night, with Polaris centred; sets both axes (needs your location).

To skip calibrating every session, use a **home position**: a fixed place to switch the mount on. The NexStar SE's elevation index on the fork arm fixes the altitude; add a mark (a strip of tape) across the joint between the arm and the base for the azimuth. It can face any direction.

1. **Once:** line up both marks, switch the mount on, connect, calibrate (Polaris is the most accurate, or level and true north), then choose **Calibrate › Save as home position**.
2. **Every session:** line up both marks before switching on. When you connect, scopeOS asks whether the mount was switched on at its home marks; choose **Yes** and the saved calibration is applied. Choose **No** if it wasn't: a home calibration from the wrong starting place puts every reading, the Sun lock and the up/down limits off by the difference.

**Use home position** applies it later if you dismissed the question, and **Forget home position** deletes it (for example after moving the base mark). End a session with **Return to home** (Control panel) before switching off, so the next session starts at the marks.

The calibration is used everywhere: the readings, the sky chart, the Sun lock and Sun distance, the 0°–75° up/down limits, and recording notes. It survives automatic reconnects and is cleared by Disconnect, because the mount may have been switched off or moved. Not needed over USB: the hand controller reports real sky positions.

## Sky map

The **Sky** tab draws the sky around where the telescope points, worked out from its angles, your location and the time, and follows it as it moves: stars to magnitude 6.5 (fainter ones appear as you zoom in), constellation lines and names, the Moon and planets, the Sun with its 30° keep-out zone, the horizon, and the telescope's crosshair with a 1° circle for scale. Drag to look around, pinch or use the magnifiers to zoom (6° to 180° across), and **Follow the telescope** to snap back.

Click a star, the Moon, a planet or any point to see its position, altitude and distance from the Sun, and **Go to** it (the same confirmation, Sun checks and Stop as any Go to; it needs a calibration). The map is only as accurate as the calibration: with a phone-compass north it may be several degrees off, which shows as the crosshair sitting beside the star you're actually looking at.

Nothing needs the internet: the star data is bundled (the Yale Bright Star Catalogue, IAU star names, and constellation lines from d3-celestial; see `Packages/ScopeKit/Sources/ScopeKit/Resources/NOTICE.txt`, and `scripts/make-sky-data.py` to rebuild it), and the Moon's and planets' positions are computed (checked against NASA JPL Horizons to within 0.02° for the planets).

## Tonight

With nothing selected on the Sky map, the panel beside it lists tonight's targets: the Moon and planets that get between 15° and the 75° up/down limit while it's dark (from the end of civil twilight to dawn), clear of the Sun's 30° keep-out, plus a bright star for focusing. Each shows when it's highest and where. Clicking one selects it on the map; Go to there still checks the route and asks first.

**Suggest** asks Apple Intelligence's on-device model (macOS 26 with Apple Intelligence on) to rank the Moon and planets for the 6SE and the camera and say what each will show. It runs on the Mac and sends nothing anywhere. It can only pick from scopeOS's own list, which also supplies the times and the facts about each planet, so it can't invent a target, and it never moves the telescope. Turn it off under **Setup › AI suggestions**. To leave it out of a build entirely, set `OnDeviceAI` to `false` in `App/Features.plist`. To see what it picks without the app: `TEST_RUNNER_SCOPEOS_LIVE_AI=1 xcodebuild test -project ScopeOS.xcodeproj -scheme ScopeOS -only-testing:ScopeOSTests/LiveAssistantTests`.

## Focus aid

While the camera preview runs, the Focus panel shows a live **sharpness** reading for the centre of the frame (keep the target on the crosshair), the percentage of the best reading so far, a 30-second trend, and the focus motor position where the best reading happened. Step the focus and watch for the peak; **Go to best** moves the focus motor back there (within its calibrated limits). It also works when focusing by hand. Readings are scaled for brightness, so changing the exposure barely moves them, and smoothed, because the air makes them flicker.

## Location

Click **Use My Location** in the Site panel (macOS asks for permission the first time), or enter latitude and longitude by hand. Macs have no GPS: Location Services finds your position from nearby WiFi networks, which is far more accurate than astronomy needs. It also needs internet, so set your location before joining the telescope's WiFi. scopeOS saves the last position.

With a location, scopeOS shows sky darkness (daylight, twilight, dark sky), the Sun's altitude, local sidereal time, the Sun on the sky chart with its 30° keep-out zone (the same one moves are held to), and the telescope's distance from the Sun over the WiFi module too (approximate, from the motor angles): red and "TOO CLOSE" inside 30°, amber inside 45°.

## Camera

The Camera panel shows and records a webcam-style (UVC) telescope camera such as the SVBONY SV205. Pick the camera and mode (YUVS 640×480 is a good start for planets), click **Start Preview**, centre the target on the crosshair, then **Record**. Recordings are uncompressed SER videos, the format stacking software reads, saved in `~/Movies/scopeOS/<date>/` with a `.txt` notes file beside each (target, time, camera mode, location and telescope pointing).

Under the preview, the histogram shows the brightness spread with the planetary target band (peak around 60–75%) and a plain-language verdict, and the camera controls (auto exposure, exposure, gamma, brightness, white balance, and gain where the camera has it) are set directly on the camera over USB. They stay set until the camera is unplugged; **Defaults** puts them back. For planets: turn auto exposure off, then shorten the exposure until nothing shows as over-exposed.

On Apple Silicon Macs these cameras often deliver no picture over USB 3: connect them through a USB 2 hub. Quit AstroDMx, FireCapture or QuickTime first so they don't hold the camera.

To test a camera from the terminal: `cd Packages/ScopeKit && swift run scopecap list` (modes), `swift run scopecap controls` (exposure, gamma… and a write test) or `swift run scopecap record 5` (a 5-second SER). Recording needs camera access for your terminal app; macOS may not show the prompt for a command-line tool, so if `record` reports no answer, allow the terminal in System Settings › Privacy & Security › Camera.

## Night vision

Click the moon in the header (or press ⇧⌘N) for a dim red-on-black display that keeps your eyes dark-adapted at the eyepiece. Turn your screen brightness down as well.

## Connecting to the telescope

| Option | How | What you get |
|---|---|---|
| **WiFi module** | Either join the scope's own WiFi (`SkyPortal-XXXX` / `Celestron-XX`; host `1.2.3.4`, port `2000`), or put the module on your home or Starlink network (SkyPortal app › Settings › Communication › Configure Access Point, then the module's switch to WLAN) and click **Find** to locate it. Close the SkyPortal app first; the module takes one connection at a time. | Motor axis angles, slewing state, device firmware, focuser position |
| **USB hand controller** | USB cable to the hand controller's port, pick the `/dev/cu.usbserial-…` port. | Full sky coordinates (RA/Dec), azimuth/altitude, alignment, tracking mode, distance from the Sun |
| **Network / simulator** | Hand-controller protocol over TCP: SkyFi-style adapters, or the simulator below. | Same as USB |

The WiFi module talks Celestron's AUX bus protocol directly to the motor boards. Sky coordinates are calculated by the hand controller, so use USB if you want RA/Dec.

## Try it without the telescope

A simulated mount is included. It cycles between Saturn, the Moon, Vega and Jupiter, slewing between them every 20 seconds.

In the app, click **Start Simulator**. scopeOS runs the simulated mount itself and connects to it. Click **Stop Simulator** to shut it down.

To run the simulator separately instead (for example, to use it with the terminal monitor):

```sh
cd Packages/ScopeKit
swift run scopesim
```

Then in scopeOS choose either:

- **Network / simulator**, host `127.0.0.1`, port `2001` (hand-controller protocol), or
- **WiFi module**, host `127.0.0.1`, port `2000` (AUX protocol).

## Terminal monitor

Useful for first contact with the real mount, since `--verbose` prints every byte:

```sh
cd Packages/ScopeKit
swift run scopeos-cli wifi                       # 1.2.3.4:2000
swift run scopeos-cli usb                        # first USB serial port
swift run scopeos-cli net 127.0.0.1 2001 --verbose
```

## Project layout

```
App/                      SwiftUI app (window, view model)
Packages/ScopeKit/
  Sources/ScopeKit/       Protocols, transports (TCP, USB serial), read-only guard, astronomy
  Sources/NexStarSimulator/  Fake mount speaking both protocols
  Sources/scopesim/       Simulator command-line tool
  Sources/scopeos-cli/   Terminal monitor
  Tests/                  Unit tests + end-to-end tests against the simulator
project.yml               XcodeGen spec (regenerate with `xcodegen generate`)
```

Run the tests with `cd Packages/ScopeKit && swift test`.

## Protocol notes

- **Hand controller (NexStar serial protocol):** single-character commands, replies end in `#`. Used here: `V` version, `m` model, `J` aligned, `L` goto in progress, `t` tracking mode, `e` precise RA/Dec, `z` precise Az/Alt, and `M` cancel GoTo for Stop. Positions are 32-bit fractions of a full turn in hex.
- **AUX bus:** packets `3B <len> <src> <dst> <cmd> <data…> <checksum>`. Used here: `0x01` get position, `0x13` slew done, `0xFE` get version, for Stop, `0x24` (move at fixed rate) with rate 0 to each motor, for nudges, `0x17` (slow GoTo) to one motor at a time, and for the focus motor (`0x12`), `0x2C` to read its calibrated limits and `0x02` (GoTo) to move it. Positions are 24-bit fractions of a turn. The bus echoes every packet, so replies are matched by source, destination and command.

These are based on Celestron's published hand-controller protocol and community documentation of the AUX bus. Expect small fixes on first contact with real hardware; the traffic log in the app (and `--verbose` in the CLI) shows exactly what was sent and received. The log's **Copy** and **Save…** buttons give the latest 5,000 lines as text, and everything since launch is also written to `~/Library/Logs/scopeOS/` (the 20 newest files are kept).

## License

scopeOS is released under the [MIT License](LICENSE).
