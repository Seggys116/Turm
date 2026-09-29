import AppKit

enum Bell {
    static func ring() {
        NSSound.beep()
        if !(NSApp?.isActive ?? true) { NSApp?.requestUserAttention(.informationalRequest) }
    }
}

enum ClipboardPermission {
    static func readClipboard() -> Data? {
        let alert = NSAlert()
        alert.messageText = "Allow this program to read your clipboard?"
        alert.informativeText = "A program running in the shell asked for the contents of the clipboard."
        alert.addButton(withTitle: "Deny")
        alert.addButton(withTitle: "Allow Once")
        guard alert.runModal() == .alertSecondButtonReturn else { return nil }
        return NSPasteboard.general.string(forType: .string)?.data(using: .utf8)
    }
}
