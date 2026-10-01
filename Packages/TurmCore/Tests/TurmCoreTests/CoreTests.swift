import Foundation
import Testing
@testable import TurmCore

private func single(_ text: String) -> String { "'" + text + "'" }

struct SSHHostCodingTests {
    @Test func decodesJSONWrittenBeforeSyncFields() throws {
        let id = UUID()
        let json = """
        {"id":"\(id.uuidString)","key":"prod","hostname":"example.com","user":"bob","port":2200,"remembersPassword":true,"sudoFill":"ask"}
        """
        let host = try JSONDecoder().decode(SSHHost.self, from: Data(json.utf8))
        #expect(host.id == id)
        #expect(host.key == "prod")
        #expect(host.port == 2200)
        #expect(host.sudoFill == .ask)
        #expect(host.identityKeyID == nil)
        #expect(host.modified == nil)
    }

    @Test func roundTripsSyncFields() throws {
        let host = SSHHost(
            key: "prod", hostname: "example.com", identityKeyID: UUID(), modified: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try JSONEncoder().encode(host)
        #expect(try JSONDecoder().decode(SSHHost.self, from: data) == host)
    }

    @Test func storeStampsModifiedOnSave() throws {
        let suite = "turm.core.tests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SSHHostStore(defaults: defaults)
        let before = Date()
        #expect(store.save(SSHHost(key: "prod", hostname: "example.com")))
        let saved = try #require(store.hosts.first)
        #expect(try #require(saved.modified) >= before)
    }
}

struct SSHRouteTests {
    @Test func parsesKnownHostAndRemainder() throws {
        let host = SSHHost(key: "prod", hostname: "example.com", user: "bob", port: 2200)
        let route = try #require(SSHRoute.parse(">prod uptime", hosts: [host]))
        #expect(route.host == host)
        #expect(route.remainder == "uptime")
        #expect(route.command(remote: false, quote: single) == "ssh -p 2200 -- 'bob@example.com' uptime")
    }

    @Test func unknownTokenSplitsPortFromDestination() throws {
        let route = try #require(SSHRoute.parse(">me@box:2222", hosts: []))
        #expect(route.host == nil)
        #expect(route.command(remote: false, quote: single) == "ssh -p 2222 -- 'me@box'")
    }

    @Test func nonRoutesAreRejected() {
        #expect(SSHRoute.parse("ls", hosts: []) == nil)
        #expect(SSHRoute.parse(">", hosts: []) == nil)
        #expect(SSHRoute.isRoute("  >prod"))
    }
}

struct ShortcutExpansionTests {
    private let api = Shortcut(kind: .directory, key: "api", name: "Backend", value: "/work/api")
    private let config = Shortcut(kind: .file, key: "cfg", name: "", value: "/work/api/config.json")
    private let checkout = Shortcut(kind: .command, key: "gco", name: "", value: "git checkout {1}")

    @Test func leadingDirectoryBecomesCd() {
        #expect(Shortcuts.expand("@api ls", in: [api], quote: single) == "cd '/work/api' && ls")
    }

    @Test func fileAndSubpathAreQuoted() {
        #expect(Shortcuts.expand("cat #cfg", in: [config], quote: single) == "cat '/work/api/config.json'")
        #expect(Shortcuts.expand("ls @api/src", in: [api], quote: single) == "ls '/work/api/src'")
    }

    @Test func commandTakesItsPlaceholderArguments() {
        #expect(Shortcuts.expand("!gco main now", in: [checkout], quote: single) == "git checkout main now")
    }

    @Test func unknownTokensAreLeftAlone() {
        #expect(Shortcuts.expand("echo @nope", in: [api], quote: single) == nil)
    }

    @Test func storeLabelFallsBackToAbbreviatedPath() throws {
        let suite = "turm.core.tests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ShortcutStore(defaults: defaults)
        #expect(store.save(api))
        #expect(store.label(for: "/work/api/src") == "Backend/src")
        #expect(store.label(for: "/elsewhere") == "/elsewhere")
    }
}

struct PathDisplayTests {
    @Test func abbreviatesHome() {
        #expect(PathDisplay.abbreviate("/Users/tester", home: "/Users/tester") == "~")
        #expect(PathDisplay.abbreviate("/Users/tester/Projects", home: "/Users/tester") == "~/Projects")
    }

    @Test func leavesOtherPathsAndSiblingPrefixesAlone() {
        #expect(PathDisplay.abbreviate("/usr/bin", home: "/Users/tester") == "/usr/bin")
        #expect(PathDisplay.abbreviate("/Users/tester2/x", home: "/Users/tester") == "/Users/tester2/x")
    }

    @Test func defaultsToTheCurrentHome() {
        #expect(PathDisplay.abbreviate(NSHomeDirectory()) == "~")
    }
}

struct TerminalPaletteTests {
    @Test func providesSixteenAnsiColours() {
        #expect(TerminalPalette.ansi.count == 16)
    }

    @Test func splitsHexIntoComponents() {
        let color = PaletteColor(light: 0x112233, dark: 0xAABBCC)
        #expect(color.components(dark: false) == (0x11, 0x22, 0x33))
        #expect(color.components(dark: true) == (0xAA, 0xBB, 0xCC))
        #expect(color.hex(dark: true) == 0xAABBCC)
    }
}
