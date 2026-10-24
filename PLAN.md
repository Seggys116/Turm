# Plan

The features coming after 1.5.0 and the version each is aimed at.

1.4.0 shipped Remote Access for the iOS app, iCloud sync and per-pane command history. 1.5.0 shipped workspace restore, git diff, the file viewer and file transfer. The iOS App Store release is in progress and isn't tied to a version below.

Shared behaviour lives in `Packages/TurmCore` and is covered by `swift test --package-path Packages/TurmCore`, which runs without launching the app. Mac and iOS tests in the Xcode scheme cover the app-side wiring the same way.

| Version | Features |
|---|---|
| 1.6.0 | Port detection and forwarding, built-in browser |
| 1.7.0 | Port forwarding to the iPad, forwarding for SSH hosts |
| 1.8.0 | Drag content and page components from the browser into a shell |
| 1.9.0 | See a Mac app on the iPad, view only |
| 1.10.0 | Control a Mac app from the iPad |

Every feature ships on macOS and iOS where it makes sense, with the shared logic in `Packages/TurmCore`. Each section says what is Mac only and why.

## 1.6.0

### Port detection and forwarding

Turm notices when a shell, or a sub-shell, starts listening on a port and offers to forward it. This is the base for the browser here and the iPad in 1.7.0.

- Detection: for each pane, find the pane's shell process and its descendants (the process tree is already looked at for the running-program icon in `RunningProgram`), then list the listening TCP sockets owned by those processes with `proc_pidfdinfo` (or `lsof -iTCP -sTCP:LISTEN -nP -p <pids>` as a fallback). Poll while a command is running and stop when the block ends. Attribute each port to the pane that owns it.
- UI: a chip on that pane when a new port appears, such as `:3000`, with a toggle for forwarding. The chip can be dismissed for that port. In Settings the suggestion can be turned off entirely, which removes the chip, and a second setting forwards every detected port automatically with no prompt. A list of ignored ports (for example 5432 and 6379) stops noisy suggestions. Cycling through several ports is a list in the chip's menu.
- Forwarding for a paired device is a new Remote Access message set (`openPort`, `portData`, `closePort`) multiplexed over the existing paired connection, which is encrypted already (`CompanionCrypto`). Add the kinds to `CompanionMessage.Kind` and mark them non-essential so an older Mac or iOS app, which `CompanionVersion` already negotiates, ignores them cleanly.
- Security: only devices already paired can reach a forwarded port. The Mac never opens a new listening socket on a network interface for this, and it connects to the target on loopback only. Forwarding is off until the user turns it on per port or sets auto. Revoking a device ends its forwards. Add all of this to the security model in `docs/remote-access.md`.
- In this release the consumer is the built-in browser on the Mac. The tunnel is built here and reused by the iPad.
- Done when: starting `npm run dev`, `python -m http.server` and a server in a sub-shell each produces one chip on the right pane, the chip disappears when the server stops, and the toggles and auto setting behave as described.

### Built-in browser

A WebKit pane (`WKWebView`) so you can look at a page without leaving Turm.

- Opened from a port chip, or by typing or dropping a URL. It's a non-shell pane, so it closes, moves between tiles and windows, and is restored with its URL.
- Address bar, back, forward, reload, and a toggle for the Web Inspector. Loads `localhost` and the forwarded ports without any certificate prompts, and shows a clear error page when the server isn't up yet, with a retry that waits for the port.
- It's a viewer. No tool calling and no automation. The page is isolated: a non-persistent data store by default so a dev site's cookies don't leak into anything, with a setting to keep them.
- Mac only. On iOS the system browser is used (1.7.0).
- Done when: it opens from a chip, survives drag between windows, and restores.

## 1.7.0

### Forwarding to the iPad

The iPad or iPhone opens the Mac's forwarded port in its own browser so the page is checked on a real screen.

- The iOS app opens a listener on the device's loopback for each forwarded port and carries the traffic over the paired connection built in 1.6.0, so the user opens `http://localhost:<port>` in Safari.
- The central problem is that iOS suspends the app when the user switches to Safari and the sockets die. A Live Activity or Dynamic Island shows that forwarding is on, which ports, and a stop button, but it doesn't keep the app running. Options to keep the connection are a Network Extension packet tunnel or app proxy (an entitlement and a VPN-style permission prompt, and App Store review needs to accept it) or background tasks that only cover short trips. Run this spike during 1.6.0 on a real device, choose one, and check Apple's guidelines for it before 1.7.0 starts. If neither works acceptably, ship the foreground-only version with an in-app browser pane and say so.
- A clear state when iOS drops the connection, and a one-tap reconnect from the Live Activity.
- Done when: a page served on the Mac loads in Safari on a physical iPad, keeps loading after switching away for a minute, and the Live Activity reflects the real state.

### Forwarding for SSH hosts

Detect and forward ports that a remote shell is listening on.

- Detection comes from the remote shell integration that already reports the folder, extended to report listening ports of the shell's process tree (`ss -ltnp` or `lsof` on the host, with a fallback when neither exists).
- Forwarding uses a channel on the pane's existing SSH connection: for the Mac this is a `ssh -O forward -L` request on the ControlMaster socket, and for iOS a direct-tcpip channel through Citadel. Once forwarded to the Mac it appears as a local port and can be opened in the browser pane or forwarded on to the iPad like any other.
- The same chip, toggles, auto setting and ignore list apply.
- Done when: a server on a remote host can be opened in the browser pane and on the iPad.

## 1.8.0

Drag content from the browser into a shell to reference it, and a component mode for pointing at page elements.

- Dragging an image from the page into a shell saves a copy to a temporary folder and puts its path in the input. Dragging a text selection puts the text in the input. Both use the same quoting as shortcuts.
- Component mode is a switch on the browser pane. With it on, hovering highlights the element under the cursor and clicking inserts a reference as plain text, for example the CSS selector, tag, a short snippet of the element's text and the page URL. Implement with a script injected through `WKUserScript` and a `WKScriptMessageHandler`, active only while the mode is on.
- This only types text at the shell's cursor. There's no tool calling and no integration with any program. The point is that a Claude Code session, or any program in that shell, can then be told about exactly that part of the page.
- Mac only, since the browser pane is Mac only.
- Done when: an image, a selection and a component each arrive as readable text in the input, and component mode leaves the page unchanged when off.

## 1.9.0 See a Mac app on the iPad

Port forwarding in 1.6.0 and 1.7.0 covers web servers. This covers everything else you might be testing: a native Mac app you are building, the iOS Simulator, an Electron app, a game. The iPad shows the live window of an app running on the Mac, so you can check it works without sitting at the Mac.

- The Mac is the host and iOS is the viewer. iOS can't capture other apps, so this is one direction. The Mac side lives in the Mac target and the shared message and codec types live in `TurmCore/Companion`.
- Capture uses ScreenCaptureKit (`SCContentFilter` with a single window or a single app, not the whole display), so only what the user picked is ever streamed. The user picks from a list of windows in the app, or from a chip on a shell when Turm sees that a project action launched an app (the Xcode run and Simulator cases are the common ones).
- Encode with VideoToolbox, HEVC where the viewer supports it and H.264 otherwise, at the viewer's resolution rather than the window's native size, with a frame rate and bitrate that adapt to how the connection is doing. On the iPad decode with VideoToolbox and draw with `AVSampleBufferDisplayLayer`.
- Transport: the existing paired connection is TLS with framed messages (`CompanionTLS`, `CompanionFrameCoder`), and a shell's output is on the same stream. Sending video over it would delay shell output behind video frames, so open a second connection on the same pairing for video, authenticated with the same pairing key, and negotiate it through `CompanionVersion` with a new non-essential message kind so older apps ignore it. Test over Tailscale as well as the local network, since that is how Remote Access is meant to be used.
- Window changes: handle the window being resized, moved to another display, minimised and closed. A closed window ends the stream with a message to the viewer, and a new window of the same app can be picked again.
- Permissions and consent, all on the Mac:
  - macOS asks for Screen Recording permission the first time. Detect when it's missing and show Settings text that explains how to grant it, since ScreenCaptureKit fails quietly without it.
  - Streaming is off by default and needs a switch in Remote Access settings, separate from shell access, so a paired device that can run commands can't also watch the screen unless that is allowed.
  - Each session needs the Mac user to approve the first time for that device and app, then it can be remembered per device.
  - While anything is streaming, the Mac shows a visible indicator in the menu bar and on the shared window's pane chip, with a stop button. Revoking a device ends its streams.
  - Document all of this in the Remote Access security model, including that window contents such as passwords on screen are visible to the viewer.
- Viewer on iOS: a pane in the iOS app next to the shells, with pinch to zoom, a fit-to-screen mode, and a connection quality indicator. Rotation and iPad split view should work.
- Also a Mac viewer, since the Remote Macs window already exists and it makes sense for one Mac to view another Mac's app with the same code. Decide whether that ships in this release or later.
- Done when: a native Mac app and the Simulator can each be viewed on a physical iPad at a usable frame rate over Wi-Fi and over Tailscale, resizing the window doesn't break the stream, and revoking the device stops it immediately.

## 1.10.0 Control a Mac app from the iPad

The iPad sends touches and keys back so the app can be used, not only watched.

- Taps become mouse clicks, drags become drags, two-finger scroll becomes scrolling, long press becomes a right click, and the hardware or on-screen keyboard types into the app. Coordinates are mapped from the viewer's view back to the captured window, accounting for the window moving and for Retina scaling.
- Injection uses `CGEvent`, which needs Accessibility permission on the Mac, a second prompt after Screen Recording. Deliver events to the target app's window only, not to whatever is frontmost, and refuse to inject when the shared window isn't the one the user chose.
- Control is a separate permission from viewing. Off by default, enabled per device in Remote Access settings, and the Mac shows a clearly different indicator while a device can control. Add a hold-to-stop shortcut on the Mac that ends control immediately.
- Make it hard to do harm by accident: no control of Turm's own windows or of System Settings, and no injection while the Mac is locked.
- Done when: a native Mac app and the Simulator can be operated from the iPad, input lands in the right window after it moves, and control stops immediately from the Mac side.
