import AppKit

extension ClipboardPermission {
    static func readClipboard(from remoteName: String?) -> Data? {
        guard let remoteName else { return readClipboard() }
        let alert = NSAlert()
        alert.messageText = "Allow \(remoteName) to read your clipboard?"
        alert.informativeText = "A program running on \(remoteName) asked for the contents of the clipboard on this Mac."
        alert.addButton(withTitle: "Deny")
        alert.addButton(withTitle: "Allow Once")
        guard alert.runModal() == .alertSecondButtonReturn else { return nil }
        return NSPasteboard.general.string(forType: .string)?.data(using: .utf8)
    }

    static func allowWrite(from remoteName: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Allow \(remoteName) to change your clipboard?"
        alert.informativeText = "A program running on \(remoteName) asked to replace the contents of the clipboard on this Mac."
        alert.addButton(withTitle: "Deny")
        alert.addButton(withTitle: "Allow Once")
        return alert.runModal() == .alertSecondButtonReturn
    }
}
