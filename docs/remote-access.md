# Remote Access

Turm on the Mac can serve its shells to the Turm app on an iPhone or iPad, and to Turm on another Mac. The phone or Mac lists its open shells, shows them as blocks and lets you type into them. The shells keep running on the Mac. See [iOS](ios.md) for the app, and [Controlling another Mac](#controlling-another-mac) for Mac to Mac.

## Turning it on

Settings > Remote Access, then switch on **Allow remote control**. The status line reads "Listening on port 7337" once the Mac accepts connections. Turm must be running with a window open for phones and other Macs to connect and for new shells to be created. Switching it off stops listening and disconnects every phone and Mac. This switch is needed only on the Mac being controlled.

- **Port:** 7337 by default. Enter a number from 1024 to 65535 and press Return to apply it. A phone or Mac that already paired keeps the port it was told, so change it in that Mac's settings on the other device too.
- **Reachable at:** lists this Mac's addresses and its hostname with the port, each with a **Copy** button. Tailscale addresses are labelled as such.

## Finding the Mac

- **Same network:** the Mac advertises itself over Bonjour on the local network, so the app and other Macs list nearby Macs without any setup.
- **Tailscale:** Bonjour does not cross Tailscale. In the app, enter the Mac's Tailscale address (it starts with `100.`) or its MagicDNS name, and the port. When you pair by QR code the app stores the Mac's addresses for you. You can add or remove addresses later in Settings > Remote Access > the Mac.

## Pairing

Click **Pair a Device...** in Settings > Remote Access. A sheet shows a QR code and an 8-digit code. To pair another Mac instead, see [Controlling another Mac](#controlling-another-mac). In the app, open Settings > Remote Access > **Pair a Mac** and either:

- **Scan QR Code:** point the camera at the sheet. The Mac pairs without further approval.
- **Enter Code:** pick the Mac from the nearby list or choose **Other Address** and give an address and port, then type the 8-digit code. Both screens then show a 6-digit check code. Compare them. If they match, click **Approve** on the Mac. If they differ, or you did not start pairing, click **Reject**. The Mac waits 60 seconds for an answer.

The QR code needs no approval because its secret is only on the Mac's screen. A typed code is short enough to be guessed, so it is not trusted until you compare the check codes.

The QR code and code work for two minutes, for one device at a time. The window closes early after 3 failed attempts, or when you close the sheet. **New Code** opens a new window. A pairing already in progress is allowed to finish after the two minutes.

Paired phones are listed under Paired devices with the date they paired, and "Connected" while they are online. **Revoke** removes the phone's key and disconnects it at once. To use it again it must pair again.

## Controlling another Mac

One Mac can pair with another Mac running Turm and work in its shells from a window. Only the Mac being controlled needs **Allow remote control** switched on. The controlling Mac does not.

### Pairing

On the Mac to be controlled, switch on **Allow remote control** and click **Pair a Device...** in Settings > Remote Access. On the other Mac, open Settings > Remote Access > Control other Macs and click **Pair with a Mac...** (the Remote Macs window has the same button, and a **Pair** button beside each nearby Mac). Choose one of:

- **Nearby:** pick the Mac from the list and type the 8-digit code.
- **Other Address:** give a host or IP address and port, then type the 8-digit code. Use this over Tailscale.
- **Pairing Link:** on the controlled Mac, click **Copy Pairing Link** in the Pair a Device sheet, then paste the link here. The link carries the secret from the QR code, so it is not compared or approved.

With a typed code, both Macs show a 6-digit check code. Compare them and click **Approve** on the controlled Mac, as in [Pairing](#pairing). The link expires with the pairing window, after two minutes. A Mac cannot pair with itself.

### Two-way pairing

Each direction is its own pairing with its own key. Pairing Mac A to control Mac B does not let B control A. Settings > Remote Access > Paired devices shows one row per Mac with two lines:

- **Can control this Mac:** that Mac may control this one. **Revoke** removes it.
- **This Mac can control it:** this Mac may control that one. **Forget** removes it.

Each can be removed without touching the other. A line that is not paired says so, and the second one offers **Pair with It...**.

### The Remote Macs window

Open it from Window > Remote Macs (Shift-Command-R) or Settings > Remote Access > Control other Macs > **Open Remote Macs**. The sidebar lists each paired Mac with its connection state and its open shells, with title, folder and the running program or a spinner while a command runs, then a green or red mark when it finishes. Macs found nearby that are not paired are listed under Nearby. Choose a shell to open it.

- Type in the bar at the bottom. When the shell is ready it runs the command. While a command runs, the text is sent to it as input, and **Interrupt** (Control-C) stops it.
- A program that takes the whole screen is shown full screen in the window, and the command bar is hidden.
- Drag to select output and press Command-C to copy it. Click a link to open it.
- Right-click a block for **Copy Command**, **Copy Output**, **Run Again** and **Save as Command Shortcut...** (or **Edit Command Shortcut...**).
- Right-click a shell for **Close Shell**. If something is still running you are asked to confirm first.
- Right-click a Mac for **New Shell...** (with an optional folder) or **Forget Mac...**. The **+** button in the toolbar creates a shell on the selected Mac, or the only paired Mac.
- **Fit to This Window:** resizes the shell on the controlled Mac to this window, and puts its size back when turned off or when you leave the shell.
- The Shortcuts menu lists the controlled Mac's folder and command shortcuts. Choose one to go to the folder or run the command when the shell is ready, or remove it. **Save Folder as Shortcut...** saves the shell's folder. Shortcuts are saved on the controlled Mac.
- The branch menu appears for shells in a git repository and switches the branch on the controlled Mac.
- **Reveal in Finder on Mac:** opens the shell's folder in Finder on the controlled Mac.

Forgetting a Mac asks for confirmation and removes its key. To control it again, pair again.

Macs reconnect on their own after a dropped connection, and when this Mac wakes from sleep. They show "Not connected" while this Mac sleeps. Updates and version differences are handled as in [Versions and updates](#versions-and-updates), and the row for the Mac shows the message.

## Versions and updates

The two devices do not need the same release of Turm. When they connect, each tells the other which messages it understands, and they agree on what to use from that. There is no protocol number to keep in step.

- If one side lacks something the other cannot work without, the connection is refused and both say which device to update. On the Mac the device's row in Settings > Remote Access shows the message, with **Check for Updates...** when the Mac is the one behind.
- If they can work together but one is older, they connect, and the older device is named with a suggestion to update it. Features the older side does not understand are left out, and on the controlling device they say which device to update.

## Changing addresses

Each time a phone or Mac connects, and whenever the controlled Mac's network or port changes while it is connected, the controlled Mac sends its current addresses and port. The connecting device puts the address it is connected through first and adds the Mac's new addresses. It drops private addresses (home network and Tailscale ranges) that the Mac no longer reports, and keeps names and public addresses you typed. A device that reaches the Mac over Tailscale after the Mac's home IP changes therefore learns the new home address too. Only the paired Mac holds the key, so a stale address that now belongs to another machine cannot pass for it.

## What the phone can do

- List the Mac's open shells with their folder, running state and progress.
- Attach to a shell and see its history as blocks, with output that follows live.
- Type a command when the shell is ready, send keys to a running command, and interrupt it.
- Create a shell, optionally in a folder, in a Turm window on the Mac. The folder must already exist.
- Close a shell. If something is still running, the phone is asked to confirm first.
- **Fit to This Device:** in a shell's options menu. It resizes the shell on the Mac to the phone's screen and puts the Mac's size back when you turn it off.

## Security

- The connection is TLS 1.2 with a pre-shared key that is unique to each paired device. The forward-secret cipher suite (ECDHE-PSK with ChaCha20-Poly1305) is offered first, so a recorded session cannot be decrypted later even if a key leaks. The only other suite offered is PSK with AES-128-GCM. Outside an open pairing window, a device that does not hold a paired key cannot complete the handshake.
- Pairing derives the device key on both sides from a key exchange that is tied to the QR secret or the typed code, so the key itself is not sent over the network.
- Each side keeps the key in its own keychain, readable only while the device is unlocked, and marked so that it is never synced to iCloud or restored to another device. iCloud sync does not carry Remote Access pairings. See [iCloud sync](icloud-sync.md).
- Connections are limited. A connection that does not authenticate within 10 seconds is dropped. An address that fails 5 handshakes within 30 seconds is blocked for 30 seconds, and the Mac accepts at most 4 unfinished connections per address, 32 in total, and 16 authenticated phones and Macs.

A paired phone or Mac can run commands in your shells as you. Pair only devices you control and revoke ones you no longer use.
