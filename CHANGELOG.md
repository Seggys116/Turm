# Changelog

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
