import Foundation
import Testing
import TurmCore
@testable import Turm

@MainActor
struct BrandIconTests {
    private static let brandKeys: [String: String] = [
        "swiftpm": "swift", "xcode": "xcode", "node": "nodejs", "deno": "deno", "python": "python",
        "go": "go", "platformio": "platformio", "cmake": "cmake", "gradle": "gradle", "maven": "apachemaven",
        "dotnet": "dotnet", "mix": "elixir", "dart": "dart",
        "just": "just", "task": "task", "docker": "docker", "terraform": "terraform",
    ]

    private func manifestKeys() throws -> Set<String> {
        let url = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Icons/manifest.json")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: [String: String]] ?? [:]
        return Set(json.values.flatMap { $0.keys })
    }

    @Test func ecosystemsWithALogoUseBrandSymbols() {
        for (id, key) in Self.brandKeys {
            #expect(ProjectEcosystem.symbol(for: id) == "brand:\(key)", "\(id)")
        }
    }

    @Test func ecosystemsWithoutALogoKeepSFSymbols() {
        for id in ["tauri", "meson", "make", "cargo", "zig", "ruby", "php", "nix", ProjectEcosystem.projectID] {
            let symbol = ProjectEcosystem.symbol(for: id)
            #expect(BrandIcons.key(in: symbol) == nil, "\(id)")
            #expect(symbol == ProjectEcosystem.fallbackSymbols[id], "\(id)")
        }
    }

    @Test func everyBrandSymbolHasAFallback() {
        for (id, key) in Self.brandKeys {
            let symbol = ProjectEcosystem.symbol(for: id)
            #expect(ProjectEcosystem.fallback(forSymbol: symbol) == ProjectEcosystem.fallbackSymbols[id], "\(id) \(key)")
        }
        #expect(ProjectEcosystem.fallback(forSymbol: "brand:unknown") == "terminal")
    }

    @Test func brandKeyParsing() {
        #expect(BrandIcons.key(in: "brand:rust") == "rust")
        #expect(BrandIcons.key(in: "brand:") == "")
        #expect(BrandIcons.key(in: "hammer.fill") == nil)
        #expect(BrandIcons.key(in: "xbrand:rust") == nil)
    }

    @Test func everyEcosystemBrandExistsInTheManifest() throws {
        let available = try manifestKeys()
        #expect(!available.isEmpty)
        for symbol in ProjectEcosystem.symbols.values {
            if let key = BrandIcons.key(in: symbol) {
                #expect(available.contains(key), "\(key)")
            }
        }
    }
}
