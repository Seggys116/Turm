import Foundation

struct KittyReply: Equatable {
    let control: String
    let message: String

    var ok: Bool {
        message == "OK"
    }

    private func value(_ key: String) -> UInt32? {
        for pair in control.split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2, parts[0] == key { return UInt32(parts[1]) }
        }
        return nil
    }

    var imageID: UInt32? { value("i") }
    var imageNumber: UInt32? { value("I") }

    static func parse(_ data: ArraySlice<UInt8>) -> KittyReply? {
        let bytes = Array(data)
        guard bytes.count >= 5, bytes[0] == 0x1B, bytes[1] == 0x5F, bytes[2] == 0x47,
              bytes[bytes.count - 2] == 0x1B, bytes[bytes.count - 1] == 0x5C
        else { return nil }
        let body = String(decoding: bytes[3..<(bytes.count - 2)], as: UTF8.self)
        guard let separator = body.firstIndex(of: ";") else { return nil }
        return KittyReply(
            control: String(body[..<separator]),
            message: String(body[body.index(after: separator)...])
        )
    }

    func normalized(fileMedium: Bool, png: Bool) -> KittyReply {
        guard !ok, let colon = message.firstIndex(of: ":") else { return self }
        let code = String(message[..<colon])
        var text = String(message[message.index(after: colon)...])
        if text.hasPrefix(" ") { text.removeFirst() }
        if fileMedium, text.hasPrefix("bad") { return KittyReply(control: control, message: "EBADF:Failed to read image file") }
        if png, text == "bad payload" { return KittyReply(control: control, message: "EBADPNG:Failed to decode PNG data") }
        return KittyReply(control: control, message: "\(code):\(text)")
    }

    func encoded(aliasing alias: (from: UInt32, to: String)?) -> [UInt8] {
        var control = self.control
        if let alias {
            control = control.split(separator: ",").map { pair in
                pair == "i=\(alias.from)" ? alias.to : String(pair)
            }.joined(separator: ",")
        }
        return Array("\u{1B}_G\(control);\(message)\u{1B}\\".utf8)
    }
}

struct KittyReplyFilter {
    var quiet = 0
    var dropsOK = false
    var alias: (from: UInt32, to: String)?
    var fileMedium = false
    var png = false

    func filtered(_ data: ArraySlice<UInt8>, reply: KittyReply?) -> ArraySlice<UInt8>? {
        guard let reply else { return data }
        if quiet == 2 { return nil }
        if reply.ok, quiet == 1 || dropsOK { return nil }
        let fixed = reply.normalized(fileMedium: fileMedium, png: png)
        guard alias != nil || fixed != reply else { return data }
        return fixed.encoded(aliasing: alias)[...]
    }
}
