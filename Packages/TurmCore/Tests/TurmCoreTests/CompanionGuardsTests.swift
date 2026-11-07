import Foundation
import Testing
@testable import TurmCore

struct CompanionGuardsTests {
    @Test func uploadsOffRefuseEveryRoot() {
        let result = CompanionUploads.roots(uploadsEnabled: false, uploadRoot: "/Users/me/Inbox", shellDirectory: "/Users/me/work")
        #expect(result == .failure(.disabled))
    }

    @Test func uploadsOnWithoutAFolderAreRefused() {
        let result = CompanionUploads.roots(uploadsEnabled: true, uploadRoot: "", shellDirectory: "/Users/me/work")
        #expect(result == .failure(.noFolder))
    }

    @Test func uploadsOnAllowTheFolderAndTheShellDirectory() {
        let result = CompanionUploads.roots(uploadsEnabled: true, uploadRoot: "/Users/me/Inbox", shellDirectory: "/Users/me/work")
        #expect(result == .success(["/Users/me/Inbox", "/Users/me/work"]))
        let bare = CompanionUploads.roots(uploadsEnabled: true, uploadRoot: "/Users/me/Inbox", shellDirectory: "")
        #expect(bare == .success(["/Users/me/Inbox"]))
    }

    @Test func frameLimitHoldsAMaximumSizeFile() throws {
        #expect(CompanionFileLimits.maxWrite == CompanionFileLimits.maxRead)
        let message = CompanionMessage.fileContents(
            id: UUID(), path: String(repeating: "a", count: 1024), data: Data(count: CompanionFileLimits.maxRead), truncated: false
        )
        _ = try CompanionFrameCoder.encode(message)
    }

    @Test func ipv4MappedAddressUsesTheIPv4Key() {
        #expect(CompanionPeerAddress.key("::ffff:192.168.1.5") == "192.168.1.5")
        #expect(CompanionPeerAddress.key("192.168.1.5") == "192.168.1.5")
    }

    @Test func ipv6AddressesShareAKeyWithinTheirSlash64() {
        let a = CompanionPeerAddress.key("2001:db8:1:2:aaaa:bbbb:cccc:dddd")
        let b = CompanionPeerAddress.key("2001:db8:1:2::1")
        let other = CompanionPeerAddress.key("2001:db8:1:3::1")
        #expect(a == b)
        #expect(a != other)
    }

    @Test func nonAddressesKeepTheirText() {
        #expect(CompanionPeerAddress.key("unknown") == "unknown")
    }

    @Test func terminalSizeClampsToTheResizeLimits() {
        #expect(CompanionTerminalSize.clamped(cols: 0, rows: 100_000) == (2, 300))
        #expect(CompanionTerminalSize.clamped(cols: 100_000, rows: -4) == (500, 2))
        #expect(CompanionTerminalSize.clamped(cols: 80, rows: 24) == (80, 24))
        #expect(CompanionTerminalSize.contains(cols: 500, rows: 300))
        #expect(!CompanionTerminalSize.contains(cols: 501, rows: 24))
    }
}
