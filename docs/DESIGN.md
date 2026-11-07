# Mousey design

Mousey lets one Mac's keyboard and trackpad control a second Mac. You push the pointer through a screen edge, and input moves to the other Mac. Universal Control does the same job, but it needs one Apple Account on both Macs. Mousey is for Macs that use different accounts.

The Mac with the keyboard is the **controller**. The other is the **target**. One universal app plays either role.

## What decides whether it feels native

Three things decide the feel, in this order.

1. **Fidelity.** A trackpad produces phases, momentum, gestures, pressure, and click counts. The target must see all of them, so the app forwards macOS's own event bytes instead of a hand-written copy of each event type.
2. **Latency.** Measured on loopback at 125 packets per second, a packet takes about 0.13 ms to cross the socket path. The rest of the delay is Wi-Fi. The app adds no buffer, no smoothing, and no timer on the motion path, so it cannot be the slow part.
3. **Safety.** A person may have no other way to reach the target. A bug that eats the controller's input is a lockout, so every failure ends with input back on the controller.

## Finding, pairing, and encrypting

The first version ran inside a Tailscale tunnel, which gave it encryption, identity, and discovery for free. Measurements showed the delay was AWDL and not the path, so the app now does those three jobs itself and needs no account or other software. A typed address can use any route, including a VPN, though only local networks have been tested.

- **Discovery.** The target advertises `_mousey._udp` under its pairing id, and the controller connects to that name, which the system resolves for each new connection, so a changed address needs no setting. A typed address takes turns with the name. Pairing uses a separate `_mousey-pair._tcp` service that exists only during the pairing step, on the controlled Mac.
- **Pairing.** Each Mac makes an X25519 key. The initiator commits to its key before seeing the other's, then both show a 6-digit code derived from the keys and nonces, and a person confirms it on both Macs. Someone in the middle has one chance in a million per attempt. The controlled Mac shows a code only after the other side reveals its key, so a stranger could otherwise try keys silently. It therefore allows one attempt per 2 seconds and 10 in total, then stops listening until a person presses Try Again. Yes is never the default button, and the other side's name is stripped of line breaks and invisible characters, keeps at most two digits, and is cut to 40 characters, because it chooses that text and it sits beside the code. A code expires after 5 minutes, because a code left on a screen invites a mistaken Yes and holds the only pairing slot. The code is never the key, because a key made from 6 digits could be cracked offline from a recording. `MouseyPair` is this state machine, with no network in it.
- **Encryption.** The derived 32-byte key lives in the Keychain and drives the system's DTLS through `NWConnection`, so the app has no cryptography of its own beyond the key agreement. Whoever completes the handshake holds the key, so it is the paired Mac. The app offers `TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256`, so a recording stays unreadable even if the key is someone's later. The system also accepts plain-PSK suites when the other side asks for them (measured), so each end drops a session on any other suite, and `--selftest` checks both. Measured on loopback at p50, a plain socket takes 0.19 ms and the shipped path 0.40 ms per round trip, and a wrong key delivers nothing.
- **Priority.** With no tunnel in the way, packets can carry `.interactiveVoice`, which asks Wi-Fi for its fastest queue. Its benefit has not been measured.

Three ideas are kept from WireGuard and magicsock:

- **State in every packet.** A packet says what is true now, so a lost packet is repaired by the next one.
- **Replaced, not repaired.** If the link goes quiet for 3 seconds the controller makes a new one, because the other side may have restarted. The new port looks like a new peer, and the newest connection to prove itself wins.
- **A steady heartbeat.** The controller sends one packet per second while idle, so it always knows whether the other Mac is there.

## Packets

The app uses one UDP socket, port 47800, and two packet types. Both are little-endian and fit inside a 1280-byte MTU. A frame's body is LZ4, because `CGEvent.data` is mostly constant: 8 real events take 915 to 1208 bytes against 2698 to 3864 raw. What fits in a frame is decided after compression.

**Frame, controller to target.** A frame is a complete snapshot of what the controller wants true.

| Field | Meaning |
| --- | --- |
| `session` | Random per app launch. A new value resets the target. |
| `seq` | Increases on every frame. The target drops any frame that is not newer than the last one it accepted. |
| `sentNanos` | Echoed back, to measure round-trip time. |
| `isRemote` | Whether input is on the target now. |
| `x`, `y` | The pointer position on the target, in the target's display coordinates. |
| `motionSeq`, `motion` | The counter and the bytes of the latest motion event, until the target confirms it. |
| `firstEventID`, `events` | Every event the target has not confirmed yet, oldest first, each with the position and `motionSeq` at capture. |
| `repeats` | Key repeats, sent once and never retried. |

**Ack, target to controller.** The target sends one ack in reply to each accepted frame and sends nothing else, so it never starts traffic to the controller.

| Field | Meaning |
| --- | --- |
| `session`, `seq`, `sentNanos` | Echoed from the frame. |
| `nextEventID` | Every earlier event has been applied. |
| `appliedMotionSeq` | The latest motion the target has applied. |
| `controlled` | The target currently acts on input. |
| `canInject` | The target has Accessibility permission. |
| `displays` | The target's active display frames. |

**What a lost, repeated, or reordered packet does.** A later frame carries everything an earlier frame carried that is still unconfirmed, so the target can drop any frame that is not newer. This one comparison handles duplicates and reordering, with no replay window and no gap buffer.

- **Pointer.** The position is absolute, and the latest value wins. The next frame repairs a lost frame.
- **Clicks, keys, scroll, gestures.** Each event has an ID and stays in every frame until acked. The next frame repairs a lost packet, or a retry if the line is quiet, after 5 ms or 1.5 round trips, whichever is longer. A retry before the answer can arrive only doubles the traffic. The target applies each ID exactly once, in capture order. A click carries its own position, so it lands where it was made.
- **Key repeats.** A repeat is sent once, and the target applies it only while that key is held. A Wi-Fi stall therefore cannot release a burst of queued characters.
- **Crossing in and out.** `isRemote` is a field in the snapshot, not a message, so there is nothing to retry. Applying the same snapshot twice changes nothing.
- **Abandoned events.** When input returns to the controller, it discards its unconfirmed events. The target accepts the jump in `firstEventID`, so typing from a stalled moment never appears late on the target.

The event payload is `CGEvent.data`, rebuilt on the target with `CGEvent(withDataAllocator:data:)`. The target patches the location and the timestamp and posts the event at `.cghidEventTap`. Motion events take this same path, so drag types, click state, and flags come from the controller's own input stack. A payload that does not rebuild is dropped and counted.

## What a real trackpad showed

A recording of a real trackpad on a MacBook Air (MacBookAir10,1, macOS 26.5.1) shaped the code. The target was a Mac mini on the same build. The self-tests replay this recording from `Tests/Fixtures/trackpad-recording.json`, which holds event bytes and no key events.

- **Compatibility.** All 2086 recorded events rebuilt on the Mac mini with their fields intact.
- **Motion deltas are whole numbers with carry.** None of the recorded deltas is fractional, and over 127 events the sum of the deltas stayed within 1.5 points of the real location. Slow motion is not lost, and on the Mac mini's 1x display one point is one pixel.
- **Deltas continue at a pinned edge.** With the pointer held at `x = 1919.98`, events kept reporting outward deltas of 10 to 100 points. Edge detection reads these deltas. A flick reaches 10 points in one event, which is why `EdgePush` also needs 80 ms of sustained pushing.
- **Finger-touch events are dropped.** Every motion event comes with a type 29 event of subtype 0, at 576 to 1208 bytes, carrying raw finger data. Forwarding them would double the traffic and overflow the datagram budget (556-byte motion plus 650-byte touch). The grab tap consumes them without forwarding. Gestures have their own subtypes: 4, 6, 8 (translation, scroll, zoom), 32 (force), and type 30 subtype 23 (dock swipe). Field 110 holds the subtype and field 132 the phase.
- **Timestamps have two units.** `CGEvent.timestamp` is in `mach_absolute_time` ticks for mouse, key, scroll, and type 14 events, and in `CLOCK_UPTIME_RAW` nanoseconds for gesture types 29 and 30. Field 169 is always in ticks. The target patches each in its own unit.
- **Real events carry non-finite values.** Field 142 of a scroll event can read as NaN, so nothing may assume that a field value is finite.
- **A tap reports its own disabling.** Turning a tap off with `CGEvent.tapEnable` delivers `tapDisabledByUserInput` to its callback, so that event means a failure only when the tap is wanted on and `CGEvent.tapIsEnabled` says it is off. Deskflow issue #10296 reports the same event when the display turns off, so the watch tap is always re-enabled.
- **The recording Mac has two displays**, 1920x1080 above 1680x1050 at an offset, so outer-edge handling across displays is required.

## What the first real runs showed

These are from the Mac mini and the MacBook Air on 2026-11-07.

- **A process started before the grant never sees it.** `AXIsProcessTrusted` turned true while `CGPreflightPostEventAccess` stayed false for over 5 minutes, and a fresh process read true. So the app relaunches itself when Accessibility turns on, and also when it turns off, which leaves no consuming tap behind.
- **Replay works from real bytes.** Pointer, clicks, double clicks, drag, typing, scroll phases and pinch all arrive. AppKit merges same-phase scrolls while its thread is busy.
- **Dropping finger-touch events keeps pinch working.** 14 magnify events arrive with them and without them.
- **`eventSourceUserData` survives posting** to the HID tap, and the panic chord, tap-disable recovery and secure-input return work with real taps on the Mac mini using posted events.
- **The MacBook Air crosses and controls the Mac mini** over the real link. The app log records round trips per capture on the controller, and network variation and work per wake on the target.

- **AWDL is the lag.** With AWDL on, the Mac mini's Wi-Fi stalled for about 90 ms every 524 ms, measured against the router with no app or tunnel in the path (36 and 37 stalls in two 20-second runs, p90 42 ms). With `awdl0` down there were 0 stalls in two runs, p90 2.9 ms. The MacBook's radio has not been measured.

Launch the live tests with `open -n` so the permission is the app's own, and keep the recording outside `~/Documents`, where reading it raises a permission prompt.

## The controller

The controller owns the pointer position and makes every decision about where input goes. It knows the target's displays from the acks. The crossing back therefore needs no round trip, and the target stays simple.

It has two event taps, and neither is in the input path while input is local.

- **Watch tap.** Listen-only, for mouse moved and dragged events. It feeds edge detection and sees no keystrokes. Whenever it is disabled, it is enabled again.
- **Grab tap.** Active, at the HID location, for all event types. It exists only during capture. A hung or crashed app therefore cannot cost the user the keyboard.

State is a small machine in `ControllerCore`:

```
local(edgePush) --push through the edge--> remote(position)
remote(position) --any exit below--------> local
```

`returnToLocal(reason)` is the only exit from `remote`, and running it twice is harmless. The liveness checks run on every event as well as on the timer, because continuous motion could otherwise keep pushing the timer back. These cause it:

- The pointer pushes through the target edge that faces the controller.
- No ack for 1 second. A shorter limit would throw the user back on an ordinary Wi-Fi stall.
- An ack says the target can no longer inject, for example because its permission was removed.
- More than 64 events waiting for an ack.
- The link fails.
- The grab tap is disabled by the system or fails.
- The panic chord, ⌃⌥⌘Esc, checked inside the tap with no network involved.
- Sleep, screen lock, session change, a clock gap of over 1 second while remote, or a termination signal.
- A main-thread watchdog sees the engine thread stalled for 2 seconds while remote. It exits the process, because the taps and the cursor state end with the process.

**Crossing is refused** while a mouse button is held, while the target has not acked in the last 2.5 seconds or since the last return, or while the ack says it cannot inject. The pointer then stops at the edge like any normal edge. Crossing needs 10 points of outward push and 80 ms of pushing, with no pause over 250 ms, so a flick toward a scroll bar at the screen edge does not jump to the other Mac. Only an outer edge counts, so a second display on that side keeps working normally. The position along the edge maps proportionally, so the whole edge of one screen reaches the whole edge of the other.

**Hiding the controller's cursor.** Deskflow issue #10225 shows that the cursor can stay visible and keep moving when it rests on the Dock or menu bar. Deskflow's older releases held the cursor at screen center instead, and this design keeps that part. Correctness does not depend on hiding, because the grab tap consumes every event. All of this runs on the engine thread, in this order:

1. Create the grab tap. It exists only during capture (1.2 to 2.3 ms on the Mac mini), because turning off Accessibility while a consuming tap exists can hang all input until a forced restart ([Apple forum report](https://developer.apple.com/forums/thread/844416), not reproduced here).
2. Set the private `SetsCursorInBackground` property, resolved with `dlsym`, and call `CGDisplayHideCursor`. A missing symbol only loses the hide.
3. Warp the cursor to the center of its display, away from the Dock and the menu bar.
4. Call `CGAssociateMouseAndMouseCursorPosition(false)`.
5. Every 250 ms, hide again and warp back if the position drifted. The shell counts hides, so restoring shows the cursor exactly that many times.

On return, the app disables and then invalidates the grab tap, warps to the edge, re-associates, and shows the cursor. The first launch always re-associates. If real use shows a visible cursor, the known next step is Deskflow's clear full-screen shield window with a blank cursor. It is left out until real use shows that it is needed, because a full-screen window has its own focus and input risks.

**Held keys.** The grab tap forwards a key's release or repeat only if it saw that key go down during this crossing. Otherwise the event passes through to the controller. A modifier held across a crossing therefore releases on the Mac that saw it pressed, and nothing sticks on the controller. `KeyRouter` is that one rule, and it covers ordinary keys and `flagsChanged` modifiers. Every forwarded event already carries the controller's modifier flags.

**Secure input.** While a password field has focus, macOS hides keystrokes from every tap. If `IsSecureEventInputEnabled()` is true at crossing, the app activates itself so the field gives up focus, and reactivates the previous app on return. It checks again 4 times per second, and if secure input stays on for about 0.5 seconds it returns to the controller, so a password cannot go to the wrong Mac.

## The clipboard

Copy on one Mac, cross, and paste on the other. It is off until a person turns it on, on each Mac, and it carries only text, links, and images, up to 1 MB of text or 10 MB for an image. Files and anything marked secret by a password manager never leave.

- **It moves only as input crosses.** The Mac that input is leaving sends what changed. The receiving Mac accepts one item per crossing, within 10 seconds, and never over something copied there since the crossing. `ClipSession` in `MouseyClip` holds this, with no network in it. This protects the keyboard Mac from a compromised controlled Mac, because only its own pointer starts a crossing. A controlled Mac cannot get the same protection from a compromised keyboard Mac, which says when it crosses. That Mac can read the controlled Mac's clipboard whenever it chooses, and it could already type anything there.
- **It has its own connection.** TLS over TCP on port 47802, so a large image never queues with pointer input. The key is derived from the pairing key, so the two connections never share one, and the suite is the same forward-secret one as the input link.
- **This app never decodes a received image.** It checks the PNG signature and hands the bytes to the clipboard. Whichever app asks the clipboard for it decodes it, and that can include clipboard managers.
- **Content is filtered both ways.** Text with control characters a keyboard could not type is refused, because a terminal acts on them invisibly, and a link must be `http`, `https`, or `mailto`.
- **Forgetting a pairing turns it off.** Turning it on was a decision about that Mac.
- **It cannot be planted on enabling.** What was on the clipboard when sharing started stays there. Only what is copied later can travel.

What it cannot do is judge content. A password copied from an ordinary app travels, and with sharing on, a compromised controlled Mac can put a harmful command on the keyboard Mac's clipboard each time you return, so the Settings text says to look before pasting into Terminal. A send-only mode would remove that, and does not exist yet.

## The target

`TargetCore` is deliberately small. It replays events, tracks what it pressed, and releases it. It decides nothing about where input goes.

- **Applying a frame.** The target posts motion and events in capture order, using each event's stamped `motionSeq` to place the latest motion before or after it.
- **Releasing.** `releaseAll()` posts an up event for every held key, modifier, and button. It ends an open scroll or gesture by replaying that stream's last real event with its phase changed, so a swipe cut off by an outage cannot leave Mission Control half open. It runs when `isRemote` goes false, when the session changes, and when no frame has arrived for 1.2 seconds. A key cannot run away during an outage, because the controller generates repeats and the target does not.
- **Draining.** After each wake, the socket is read until empty, and consecutive motion posts collapse into the last one. Motion never queues behind motion.
- **Waking.** The target calls `IOPMAssertionDeclareUserActivity` at most once per second while events arrive, so input wakes its display like a real keyboard.
- **Starting.** With permission, the target posts a clear of the modifier flags and an up for each mouse button at launch, so a crash in the middle of a hold converges.

**Who can inject.** Only this process, and only for a frame that arrived over a DTLS connection, which means its sender holds the key from pairing.

**Different versions.** A frame from another version of the app gets a small notice in reply, and both Macs say to update instead of "not answering".

## Threads

Each role has one engine thread that owns all mutable state. `NWConnection` delivers on a system queue, so the target hands packets to its thread through a small mailbox, and the controller through its run loop. It runs at real-time priority, which removed scheduling outliers in a loopback test (0 of 7500 packets over 1 ms, against 2 of 7500 at `userInteractive`, three rounds). The main thread draws the menu. It gets a status snapshot at most 4 times per second and sends commands through a one-slot mailbox. The app holds `ProcessInfo.beginActivity(.latencyCritical)` to prevent App Nap, and allows idle sleep. The target's slow system calls run on their own queue, because `CGPreflightPostEventAccess` takes 6 to 9 ms (measured in a process without the permission).

## The app

A menu bar item, plus a Dock icon only while a window is open. The menu has the status line, Settings, Help, and the tutorial.

**The look is black and white, and follows the system's light or dark mode.** There is no accent colour, so state shows through form: filled against outlined, pressed against raised. The pointer is the app's character, buttons are keys that move when pressed, the pairing code sits on keycaps, the escape keys light up as they are held, and the desk picture shows where the real pointer is. `Sources/Mousey/Design.swift` holds all of it. Moving things hold a still pose under Reduce Motion.

**The tutorial teaches by doing.** Each step checks the real result. The keyboard Mac goes through welcome, role, Accessibility, pairing, arrangement, a real crossing and return, the escape shortcut, and Wi-Fi smoothing. The controlled Mac goes through the same start, then waits and shows when it is being controlled. The step is saved, because granting Accessibility restarts the app.

**A sentence and a button.** The status line names the one thing to fix when something is wrong, in this order: not paired, missing Accessibility, port unavailable, refused input, different versions, the other Mac not answering, a password field blocking input.

**Settings is one screen with no scrolling.** The other Mac's name and one status line come first, with a small picture of how the screens sit. Below are the position and one switch per feature, and the shortcut and Forget are at the bottom. The app's timing now lives in its log, so the latency test is gone from the window.

**Wi-Fi smoothing** is optional, explained in the tutorial, and installed behind the system's password prompt. See "AWDL is the lag" above. The helper switches only AWDL. A lease is an open connection to it, so a crashed app ends its lease.

**Distribution** is a disk image signed with a stable self-signed identity, because no paid Apple account is in use. The binaries are stripped, because debug info holds the build folder's path. They use the hardened runtime, because without it another program can load its code into the app and hold the app's permissions (measured). The first open needs Open Anyway in System Settings, and `docs/INSTALL.md` says so. Permissions survive updates because the signing identity does not change. A Developer ID build would remove that step.

**Updates are notices.** Once a day the app asks GitHub for the latest release tag, and shows a new version with a dot on the menu bar icon, a menu item, and a button in Settings. Each of these opens a fixed release page. The app installs nothing, because an app that can read keystrokes must not replace itself on the word of a server. A tag appears only if it is digits and dots. The check starts on, because it is how a security fix reaches people, and a switch in Settings turns it off. Each day has one try, so the request waits up to 5 minutes for a network instead of failing right after a wake.

## Code layout

`MouseyCore` and `MouseyPair` hold the pure logic, with no AppKit, no network, and no event taps, and time is passed in. `MouseyLease` is the AWDL lease on both ends. `MouseyHelper` is the small root daemon. `Mousey` is the macOS shell.

| File | Owns |
| --- | --- |
| `MouseyCore/Wire.swift` | Encoding and decoding `Frame` and `Ack`. |
| `MouseyCore/EventStream.swift` | `Outbox` and `Inbox`. |
| `MouseyCore/Geometry.swift` | Displays, outer edges, `EdgePush`, and mapping along an edge. |
| `MouseyCore/ControllerCore.swift` | The focus state machine, the pointer position, and `KeyRouter`. |
| `MouseyCore/Release.swift` | Comparing release numbers, and when the update check is due. |
| `MouseyClip/Clip.swift` | Clipboard items, frames, and the rules on when an item may move. |
| `MouseyCore/TargetCore.swift` | Replay order and held input. |
| `Mousey/ControllerEngine.swift` | The taps, the engine thread, and the cursor. |
| `MouseyPair/Pairing.swift` | The pairing state machine. |
| `MouseyLease/Lease.swift` | The lease client and server. |
| `Mousey/TargetEngine.swift` | The receive loop and event posting. |
| `Mousey/SecureLink.swift` | DTLS client, listener, mailbox, and finding the paired Mac. |
| `Mousey/PairingChannel.swift` | Carrying pairing messages, and advertising or browsing for pairing. |
| `Mousey/AppModel.swift` | Everything windows and the menu show, and the engines' lifetime. |
| `Mousey/Onboarding.swift`, `SettingsView.swift` | The tutorial, settings, and help. |
| `Mousey/App.swift` | The menu bar item and windows. |
| `Mousey/Paired.swift` | Saved choices, the Keychain, and installing the helper. |
| `Mousey/ClipboardSync.swift` | Reading and writing the clipboard, and its encrypted connection. |
| `Mousey/UpdateCheck.swift` | Asking GitHub for the latest release number. |
| `Mousey/SelfTest.swift` | The end-to-end checks that need no permission. |

## How it is verified

**With no permission.** `swift test` runs the cores through a simulated link with seeded loss, duplication, reordering, and partition. The properties are: every event applied exactly once and in capture order, final position equal to the clamped sum of motion, a click landing where it was captured, nothing held at the end, and both sides idle after a partition. Fuzzing covers the frame decoder. `--selftest` runs the real encrypted link and pairing on `127.0.0.1`, with real `CGEvent` bytes and a fake injector. `--render-screens` draws every tutorial step and window to a PNG for review, without Screen Recording permission. Tests bind only loopback, because a new binary that binds another address raises a firewall prompt.

**After you grant Accessibility to a debug build.** These modes post real events, so they exist only in debug builds. `CONFIG=debug scripts/build-app.sh` writes one to `dist/debug/` under its own bundle id, so it cannot inherit a grant made to the real app. Any program running as you can use a debug build that holds a grant, so run `tccutil reset Accessibility io.github.imsumitkumar.mousey.debug` after a test session. Never publish a debug build. `--selftest-inject` posts real events and observes them in a test window. It checks pointer position, a double click, a drag, typed text, scroll phases, and magnify events. `--selftest-loop` runs real taps over the encrypted link. `--selftest-live` checks the Keychain from a signed app.

**Before publishing.** `scripts/check-public.sh` fails if a file that would go public holds a secret or a personal detail. It prints the file and line, and never the match. `scripts/test-check-public.sh` plants each kind of problem to prove that the check catches it. `scripts/verify.sh` runs both.

**By a person, on two Macs.** These need a real trackpad and network: the feel of crossing and motion, gestures, and cursor hiding with the Dock on each edge.

**The recording.** `Tests/Fixtures/trackpad-recording.json` came from an input recorder that has since been removed. It stored event types and bytes and never stored key events, and `--selftest` checks that it holds none.

## Left out on purpose

File transfer, dragging across Macs, three or more Macs, a keyboard shortcut to switch, and pointer speed scaling are out. Any of them can be added later without changing the packet design.

## Known risks

- **Gesture replay.** Whether taps see gesture events and whether posting them moves Mission Control can only be tested on two real Macs.
- **`CGEvent.data` across macOS versions.** The two Macs may run different versions. `--selftest-inject` checks replay on each new macOS. If replay fails, only the payload changes, because `MouseyCore` treats it as opaque bytes.
- **Disassociation in a background app.** Apple documents it for foreground apps. Consuming events is the correctness layer, so the worst case is a visible cursor at the center of the controller's screen.
- **Crash while remote.** The taps and the cursor state should end with the process. The first launch re-associates anyway, and a `kill -9` drill confirms the rest.
- **Wi-Fi.** A packet between two Macs on Wi-Fi crosses the air twice. AWDL was the measured cause of stalls here, and Ethernet remains the other fix.
- **Discovery on real networks.** Guest networks and some routers block it, so pairing also accepts a typed address.

## Design history

Three independent designs were compared for the first version, and all three agreed on the tunnel as identity, no custom cryptography, and one idempotent exit. The tunnel was later replaced, as described above. This design takes the controller-owned pointer, raw motion events, and the startup convergence from one candidate, and the disabled grab tap with a separate listen-only tap from the other. It keeps its own snapshot frames, which recover from loss in about one frame instead of a 25 ms retransmit timer and need no replay window. It rejects a hand-written event format and a shared-key tag, because they add code and lose fidelity with no gain on a tunnel. It rejects a 300 ms silence limit, because that would throw the user back on ordinary Wi-Fi stalls.
