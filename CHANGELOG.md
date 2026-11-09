# Changelog

## 2.1.0

- With the sidebar collapsed, a top bar shows the space menu, a chip for each shell and a dock button. The sidebar can also pop out over the card. Appearance settings turn either one off, but not both, and the sidebar has a hide button at its top.
- One graphics engine now draws Kitty images on macOS and iOS, in block output and in full-screen programs. It handles animation, image quotas, cropped Unicode placeholders, every delete mode, and shared memory images sent with an offset or size. Images can sit above or beneath the text, and block output stays complete while a full-screen program is up.
- Sixel images are decoded by Turm, with size limits checked before anything is drawn. Programs that ask about graphics support get an answer, and iTerm2 images accept percent sizes and the option to leave the cursor where it was.
- Pairing a phone asks you to compare the check code on both devices, and the Mac stores the device only after the phone confirms. A device that is already paired is refused before anything is stored, and the plain AES cipher suite is no longer offered.
- Remote access is stricter. Uploads only land in the folders you chose, file reads are bounded, idle connections are cut off after repeated strikes, terminal sizes from a phone are clamped, and links and clipboard writes from remote output ask first.
- The iPhone and iPad app tries every known address of a Mac at once and keeps the first one that answers, and it reconnects sooner after a drop. The Mac retries its listener faster when the port is still busy, and a successful pairing clears earlier failed attempts.
- Saving the workspace happens off the main thread, and output rendering and escape scanning do less work.

## 2.0.2

- A full-screen program such as Claude Code no longer opens as a black pane that only fills in after the pane is resized. The program is told the size the pane really ends up at, even when the pane changes size several times while it opens, and the pane is redrawn once it has its final size.

## 2.0.1

- The search popup opened with Cmd+T stays on screen when the sidebar is collapsed.

## 2.0.0

- Saved spaces are shared across windows, and a space is shown in one window at a time.
- The sidebar slides over the card.
- Images a program sends to the shell are drawn. A full-screen terminal GUI is one picture, sized to the pane, and clicks land where they are drawn.
- Tmp keeps a fresh shell when its last one exits.
- Finder registers the folders on an external disk so the disk keeps its own icon.
- On iPhone and iPad, the session list sits in the app chrome, with back, the keyboard and the session menu in the strip.
- The pairing code closes from Done.

## 1.5.0

- Turm remembers your windows, tiles and shells and brings them back after a quit or a crash, along with recent blocks and each pane's working directory.
- Git changes sit in a menu on the block header. It shows unstaged, staged or single-commit diffs with the changed words picked out inside each line, and it can create a new branch.
- A file sidebar lists the shell's folder, on this Mac or over SSH. Show or hide it from the folder chip.
- Files open in an editor with syntax colours, and images and videos open in a viewer. Saving writes back to the host.
- Copy, move and drag files between the Mac, SSH hosts and the sidebar. A transfer list shows progress and speed and lets you cancel.
- A paired iPhone or iPad can list a Mac shell's folder, read a file, ask for a git diff, and upload into a folder you pick. Uploads are off until you turn them on in Settings, and anything outside that folder is refused.
- The iOS app posts a notification when a command finishes in a Mac shell it is attached to, and remembers the SSH hosts you had open. They come back disconnected.
- Popover menus open again after closing.

## 1.4.1

- iPad sessions can be dragged into another window or out to a new one without closing, and chrome has a right click menu.
- The iOS bars follow the system's vertical bar column and the foldable top inset, sheets keep their bar on top, and menus stay over their own column.
- Pointer wheel scrolling works in full-screen programs, and Shift+Return or the key bar inserts a newline without submitting.
- Keys typed into a program that exits before reading them no longer land on the next prompt.
- The Finder extension can copy the selected paths, toggled in Settings.
- Git status works on external drives that ignore ownership, and unreadable folders say how to grant access.
- CI and releases build on Xcode 27.
