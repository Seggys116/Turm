import CryptoKit
import Foundation
@testable import TurmCore

enum KeyFixtures {
    static let edSeed = Data((0..<32).map { UInt8($0 &* 7 &+ 3) })

    static func u32(_ value: UInt32) -> Data {
        Data([UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }

    static func string(_ data: Data) -> Data { u32(UInt32(data.count)) + data }

    static func string(_ text: String) -> Data { string(Data(text.utf8)) }

    static func mpint(_ bytes: [UInt8]) -> Data {
        var trimmed = Array(bytes.drop { $0 == 0 })
        if trimmed.first.map({ $0 & 0x80 != 0 }) ?? false { trimmed.insert(0, at: 0) }
        return string(Data(trimmed))
    }

    static func armor(_ raw: Data, label: String, headers: [String] = []) -> String {
        let encoded = raw.base64EncodedString()
        var lines: [String] = []
        var index = encoded.startIndex
        while index < encoded.endIndex {
            let next = encoded.index(index, offsetBy: 70, limitedBy: encoded.endIndex) ?? encoded.endIndex
            lines.append(String(encoded[index..<next]))
            index = next
        }
        let middle = headers.isEmpty ? lines : headers + [""] + lines
        return (["-----BEGIN \(label)-----"] + middle + ["-----END \(label)-----"]).joined(separator: "\n") + "\n"
    }

    static func container(cipher: String = "none", publicBlob: Data, privateSection: Data) -> Data {
        var padded = privateSection
        var pad: UInt8 = 1
        while padded.count % 8 != 0 {
            padded.append(pad)
            pad += 1
        }
        return Data("openssh-key-v1\0".utf8) + string(cipher) + string(cipher == "none" ? "none" : "bcrypt") + string(Data())
            + u32(1) + string(publicBlob) + string(padded)
    }

    static var edPublic: Data {
        (try? Curve25519.Signing.PrivateKey(rawRepresentation: edSeed).publicKey.rawRepresentation) ?? Data()
    }

    static var edBlob: Data { string("ssh-ed25519") + string(edPublic) }

    static var edPublicLine: String { "ssh-ed25519 " + edBlob.base64EncodedString() }

    static func ed25519(cipher: String = "none") -> String {
        let check = u32(0xA1B2_C3D4)
        let section = check + check + string("ssh-ed25519") + string(edPublic) + string(edSeed + edPublic) + string("fixture")
        return armor(container(cipher: cipher, publicBlob: edBlob, privateSection: section), label: "OPENSSH PRIVATE KEY")
    }

    // 3233 = 61 * 53, e = 17, d = 2753: tiny but arithmetically valid, enough for the container layout.
    static let rsaN: [UInt8] = [0x0C, 0xA1]
    static let rsaE: [UInt8] = [0x11]

    static var rsaBlob: Data { string("ssh-rsa") + mpint(rsaE) + mpint(rsaN) }

    static var rsaPublicLine: String { "ssh-rsa " + rsaBlob.base64EncodedString() }

    static func rsa() -> String {
        let check = u32(0x0102_0304)
        let section = check + check + string("ssh-rsa") + mpint(rsaN) + mpint(rsaE) + mpint([0x0A, 0xC1]) + mpint([0x26])
            + mpint([0x3D]) + mpint([0x35]) + string("fixture")
        return armor(container(publicBlob: rsaBlob, privateSection: section), label: "OPENSSH PRIVATE KEY")
    }

    static func pemRSA(encrypted: Bool = false) -> String {
        let integers: [[UInt8]] = [[0x00], rsaN, rsaE, [0x0A, 0xC1], [0x3D], [0x35], [0x35], [0x31], [0x26]]
        var body: [UInt8] = []
        for number in integers {
            var value = Array(number.drop { $0 == 0 })
            if value.isEmpty { value = [0] }
            if value[0] & 0x80 != 0 { value.insert(0, at: 0) }
            body += [0x02, UInt8(value.count)] + value
        }
        let der = Data([0x30, UInt8(body.count)] + body)
        let headers = encrypted ? ["Proc-Type: 4,ENCRYPTED", "DEK-Info: AES-128-CBC,0123456789ABCDEF0123456789ABCDEF"] : []
        return armor(der, label: "RSA PRIVATE KEY", headers: headers)
    }
}

nonisolated final class MemoryBacking: SecretBacking, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    var failWrites = false

    func read(_ account: String) -> Data? { lock.withLock { items[account] } }

    func write(_ account: String, data: Data, label: String) -> Bool {
        lock.withLock {
            guard !failWrites else { return false }
            items[account] = data
            return true
        }
    }

    func remove(_ account: String) { lock.withLock { items[account] = nil } }

    var accounts: [String] { lock.withLock { Array(items.keys) } }
}
