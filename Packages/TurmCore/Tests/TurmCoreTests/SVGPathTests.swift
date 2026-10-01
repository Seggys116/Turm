import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import TurmCore

struct SVGPathTests {
    private func parse(_ data: String) -> Path? {
        SVGPath.path(from: data)
    }

    private func expectSame(_ compact: String, _ explicit: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let left = parse(compact)
        #expect(left != nil, sourceLocation: sourceLocation)
        #expect(left == parse(explicit), sourceLocation: sourceLocation)
    }

    @Test func squareHasItsBoundingBox() throws {
        let box = try #require(parse("M0 0H24V24H0Z")).boundingRect
        #expect(box == CGRect(x: 0, y: 0, width: 24, height: 24))
    }

    @Test func relativeCommandsMatchAbsolute() {
        expectSame("m10 10 l5 0 h5 v5 z", "M10 10 L15 10 H20 V15 Z")
        expectSame("M0 0 c1 2 3 4 5 6", "M0 0 C1 2 3 4 5 6")
        expectSame("M1 1 q2 2 4 0", "M1 1 Q3 3 5 1")
    }

    @Test func extraCoordinatePairsRepeatTheCommand() {
        expectSame("M0 0 10 10 20 0", "M0 0 L10 10 L20 0")
        expectSame("m0 0 10 10 10 -10", "M0 0 L10 10 L20 0")
        expectSame("M0 0 H5 10 15", "M0 0 H5 H10 H15")
        expectSame("M0 0 C1 1 2 2 3 3 4 4 5 5 6 6", "M0 0 C1 1 2 2 3 3 C4 4 5 5 6 6")
    }

    @Test func compactNumbersSplitAtTheSecondDecimalPointOrSign() {
        expectSame("M1.2.3", "M1.2 0.3")
        expectSame("M0 0L-.5-.5", "M0 0 L-0.5 -0.5")
        expectSame("M0,0,L1,1", "M0 0 L1 1")
        expectSame("M1e-3 0", "M0.001 0")
        expectSame("M1E2 +3", "M100 3")
    }

    @Test func arcFlagsMayBeWrittenWithoutSeparators() {
        expectSame("M0 0a1 1 0 011 1", "M0 0 a1 1 0 0 1 1 1")
        expectSame("M0 0A5 5 0 1010 0", "M0 0 A5 5 0 1 0 10 0")
    }

    @Test func smoothCurvesReflectThePreviousControlPoint() {
        expectSame("M0 0 C0 10 10 10 10 0 S20 -10 20 0", "M0 0 C0 10 10 10 10 0 C10 -10 20 -10 20 0")
        expectSame("M0 0 Q5 10 10 0 T20 0", "M0 0 Q5 10 10 0 Q15 -10 20 0")
        expectSame("M0 0 Q5 10 10 0 T20 0 T30 0", "M0 0 Q5 10 10 0 Q15 -10 20 0 Q25 10 30 0")
    }

    @Test func smoothCommandsWithoutAPreviousCurveUseTheCurrentPoint() {
        expectSame("M0 0 S5 5 10 0", "M0 0 C0 0 5 5 10 0")
        expectSame("M0 0 L4 0 T8 0", "M0 0 L4 0 Q4 0 8 0")
        expectSame("M0 0 Q5 5 10 0 L12 0 T20 0", "M0 0 Q5 5 10 0 L12 0 Q12 0 20 0")
    }

    @Test func arcEndsAtItsEndPoint() throws {
        let cases: [(String, CGPoint)] = [
            ("M0 0 A5 5 0 0 1 10 0", CGPoint(x: 10, y: 0)),
            ("M0 0 A5 5 0 1 0 10 0", CGPoint(x: 10, y: 0)),
            ("M3 4 a2 7 30 1 1 -5 2", CGPoint(x: -2, y: 6)),
            ("M3 4 a2 7 30 0 1 -5 2", CGPoint(x: -2, y: 6)),
            ("M1 1 A1 1 0 0 1 100 3", CGPoint(x: 100, y: 3)),
            ("M0 0 a3 3 0 1 1 0.001 0", CGPoint(x: 0.001, y: 0)),
        ]
        for (data, expected) in cases {
            let end = try #require(parse(data)?.currentPoint, "\(data)")
            #expect(abs(end.x - expected.x) < 1e-9 && abs(end.y - expected.y) < 1e-9, "\(data)")
        }
    }

    @Test func semicircleBoundingBox() throws {
        let box = try #require(parse("M0 0 A5 5 0 0 1 10 0")).boundingRect
        #expect(abs(box.width - 10) < 1e-6)
        #expect(abs(box.height - 5) < 1e-6)
    }

    @Test func tooSmallRadiiAreScaledUp() throws {
        let box = try #require(parse("M0 0 A1 1 0 0 1 10 0")).boundingRect
        #expect(abs(box.width - 10) < 1e-6)
        #expect(abs(box.height - 5) < 1e-6)
    }

    @Test func circleFromTwoArcsHasItsDiameter() throws {
        let box = try #require(parse("M12 2a10 10 0 1 0 0 20a10 10 0 1 0 0-20z")).boundingRect
        #expect(abs(box.width - 20) < 1e-6)
        #expect(abs(box.height - 20) < 1e-6)
    }

    @Test func zeroRadiusArcIsALine() {
        expectSame("M0 0 A0 5 0 0 1 10 0", "M0 0 L10 0")
        expectSame("M0 0 A5 0 0 0 1 10 0", "M0 0 L10 0")
    }

    @Test func drawingAfterCloseStartsAtTheSubpathStart() {
        expectSame("M10 10 L20 10 Z l5 5", "M10 10 L20 10 Z M10 10 L15 15")
    }

    @Test func malformedDataIsRejected() {
        #expect(parse("") == nil)
        #expect(parse("   ") == nil)
        #expect(parse("L0 0") == nil)
        #expect(parse("M0") == nil)
        #expect(parse("M0 0 L1") == nil)
        #expect(parse("M0 0 L1 1 2") == nil)
        #expect(parse("M0 0 X1 1") == nil)
        #expect(parse("M0 0 a1 1 0 2 1 1 1") == nil)
        #expect(parse("M0 0 a1 1 0 0") == nil)
        #expect(parse("M0 0 Z 1 1") == nil)
        #expect(parse("M0 0 L1e999 1") == nil)
        #expect(parse("M. 0") == nil)
        #expect(parse("M- 0") == nil)
    }

    @Test func everyManifestIconParses() throws {
        guard let root = Self.repositoryRoot() else { return }
        let modules = root.appendingPathComponent("Icons/node_modules")
        guard FileManager.default.fileExists(atPath: modules.path) else { return }
        let manifest = try JSONDecoder().decode([String: [String: String]].self, from: Data(contentsOf: root.appendingPathComponent("Icons/manifest.json")))
        let folders = ["simple-icons": "simple-icons/icons", "lobe": "@lobehub/icons-static-svg/icons"]
        var checked = 0
        for (source, icons) in manifest {
            guard let folder = folders[source] else { continue }
            for (key, slug) in icons {
                let file = modules.appendingPathComponent(folder).appendingPathComponent("\(slug).svg")
                guard let svg = try? String(contentsOf: file, encoding: .utf8) else { continue }
                let paths = svg.components(separatedBy: " d=\"").dropFirst().compactMap { $0.components(separatedBy: "\"").first }
                #expect(!paths.isEmpty, "\(key)")
                for data in paths {
                    #expect(parse(data) != nil, "\(key)")
                }
                checked += 1
            }
        }
        #expect(checked > 0)
    }

    static func repositoryRoot() -> URL? {
        var directory = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("Icons/manifest.json").path) { return directory }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }
}

@MainActor
struct BrandIconsTests {
    private let square = BrandGlyphData(viewBox: [0, 0, 24, 24], evenOdd: false, paths: ["M0 0H24V24H0Z"])

    @Test func symbolKeys() {
        #expect(BrandIcons.key(in: "brand:rust") == "rust")
        #expect(BrandIcons.key(in: "brand:") == "")
        #expect(BrandIcons.key(in: "hammer.fill") == nil)
        #expect(BrandIcons.key(in: "xbrand:rust") == nil)
    }

    @Test func shapeFitsTheViewBoxAspectAndCentres() {
        let box = BrandShape(square).path(in: CGRect(x: 0, y: 0, width: 48, height: 24)).boundingRect
        #expect(box == CGRect(x: 12, y: 0, width: 24, height: 24))
        let half = BrandShape(square).path(in: CGRect(x: 10, y: 20, width: 12, height: 12)).boundingRect
        #expect(half == CGRect(x: 10, y: 20, width: 12, height: 12))
    }

    @Test func viewBoxOriginIsHonoured() {
        let data = BrandGlyphData(viewBox: [10, 10, 20, 20], evenOdd: true, paths: ["M10 10H30V30H10Z"])
        let shape = BrandShape(data)
        #expect(shape.evenOdd)
        #expect(shape.path(in: CGRect(x: 0, y: 0, width: 40, height: 40)).boundingRect == CGRect(x: 0, y: 0, width: 40, height: 40))
    }

    @Test func glyphsLoadFromTheBundleOverride() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("BrandIcons")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try JSONEncoder().encode(["square": square]).write(to: folder.appendingPathComponent("BrandIcons.json"))

        let previous = BrandIcons.bundle
        defer { BrandIcons.bundle = previous }
        BrandIcons.bundle = try #require(Bundle(url: root))
        let loaded = try #require(BrandIcons.glyph("square"))
        #expect(loaded.paths == square.paths)
        #expect(loaded.viewBox == square.viewBox)
        #expect(BrandIcons.glyph("missing") == nil)
        #expect(BrandIcons.shape("square") != nil)
        #expect(BrandIcons.shape("missing") == nil)
    }
}
