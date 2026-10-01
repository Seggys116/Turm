# Turm for iPhone and iPad

The iOS app does two things. It opens the shells of a Mac running Turm, and it connects straight to servers over SSH. Hosts, shortcuts, passwords and keys can follow you between devices with [iCloud sync](icloud-sync.md).

## Layout

The app is a sidebar and a session view. On a wide screen such as an iPad's they sit side by side. On an iPhone the sidebar is the first screen, opening or selecting a session shows it, and closing the last one returns to the sidebar. The layout follows the width the app is given, not the device, so iPhone Duo uses the iPhone layout when folded and the side-by-side layout when open, and an iPad window switches as it is resized.

The sidebar has three sections:

- **Open Sessions:** the sessions you have open, from any source. Swipe or long-press to close one. Above a session, a tab strip switches between them, and its **+** starts a new one.
- **Macs:** paired Macs and the Macs found nearby. Each paired Mac lists its shells, with a badge for activity and progress, and **New Shell** creates one on the Mac. A Mac that could not be reached offers **Try Again**. Long-press a Mac to refresh it or forget it. **+** pairs a Mac. See [Remote Access](remote-access.md) for pairing.
- **SSH Hosts:** your saved hosts. Tap one to connect. Swipe or long-press to edit or delete it. **+** adds a host.

The gear opens Settings.

## Shells on a Mac

Opening a Mac's shell shows its history as blocks, one per command with its exit code and folder, as on the Mac. The input bar below takes a command. The arrows beside it recall earlier commands. While a command runs, the bar shows "Running. Keys go to the command." and an **Interrupt** button. Full-screen programs such as `vim` or `htop` appear as a terminal.

A banner at the top shows when the Mac is not connected, is reconnecting, or closed the shell. The app disconnects when it goes to the background and reconnects when you return. The options menu has **Fit to This Device**, which sizes the shell on the Mac to your screen.

## SSH from the phone

Add a host with **+** under SSH Hosts:

- **Name:** the key for the host. With iCloud sync on, the same name works with `>` in Turm on the Mac.
- **Host, User and Port:** user and port are optional.
- **Sign in with:** Password, or a key you imported in Settings > SSH Keys. With a password, **Remember in Keychain** stores it on this device, or in iCloud Keychain when sync is on. Without it Turm asks when you connect, and a prompt can also ask for the user.

Settings > SSH Keys imports a private key from Files or from a pasted text, with an optional passphrase, and can copy a key's public half.

The first time you connect to a server, Turm shows the host key fingerprint and asks **Trust and Connect**. It remembers the key for that host and port on this device and checks it every time after. If a server later presents a different key, Turm refuses to connect and offers **Forget Saved Key** or **Dismiss**. Settings > Trusted Hosts lists the saved keys and removes them. Trusted hosts do not sync.

If a connection drops, a bar offers **Reconnect**. The **Keyboard** button in the toolbar brings up the keyboard for an SSH session.

## Keyboard bar

A row of terminal keys sits above the keyboard in SSH sessions and in a Mac shell's input bar.

- **ctrl and alt:** tap once to apply to the next key. Double-tap to lock until you tap again.
- **Arrows, tab, home, end, pgup, pgdn:** hold to repeat.
- **Drag pad:** drag on it to move the cursor.
- **Paste:** pastes the clipboard.
- **fn:** the pinned button at the right switches the bar to ctrl, alt and F1 to F12. **abc** switches back. The button next to it hides the keyboard.

To change the bar, open Settings > Keyboard Bar > **Customize Keys**. Drag to reorder, delete a key to move it to Available, tap an available key to add it, and **Reset to Default** to restore the original. The available keys are esc, tab, ctrl, alt, the four arrows, the drag pad, home, end, pgup, pgdn, paste and these symbols: `| ~ / - _ : ; ` ' " $ & * < > { } [ ]`. **Haptic Feedback** turns tap feedback on or off.

Settings also sets the font size, which you can change by pinching the terminal, and holds the Remote Access and iCloud Sync sections.
