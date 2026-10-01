import CoreGraphics
import Foundation
import SwiftUI

public nonisolated struct BrandGlyphData: Codable, Sendable {
    public var viewBox: [Double]
    public var evenOdd: Bool
    public var paths: [String]

    public init(viewBox: [Double], evenOdd: Bool, paths: [String]) {
        self.viewBox = viewBox
        self.evenOdd = evenOdd
        self.paths = paths
    }
}

public enum BrandIcons {
    public nonisolated static let prefix = "brand:"

    public static var bundle: Bundle = .main {
        didSet {
            catalog = nil
            shapes = [:]
        }
    }

    private static var catalog: [String: BrandGlyphData]?
    private static var shapes: [String: BrandShape] = [:]

    public static func glyph(_ key: String) -> BrandGlyphData? {
        loaded()[key]
    }

    public static func shape(_ key: String) -> BrandShape? {
        if let cached = shapes[key] { return cached }
        guard let data = glyph(key) else { return nil }
        let shape = BrandShape(data)
        shapes[key] = shape
        return shape
    }

    public nonisolated static func key(in symbol: String) -> String? {
        symbol.hasPrefix(prefix) ? String(symbol.dropFirst(prefix.count)) : nil
    }

    private static func loaded() -> [String: BrandGlyphData] {
        if let catalog { return catalog }
        var decoded: [String: BrandGlyphData] = [:]
        if let url = bundle.url(forResource: "BrandIcons", withExtension: "json", subdirectory: "BrandIcons"),
           let data = try? Data(contentsOf: url),
           let table = try? JSONDecoder().decode([String: BrandGlyphData].self, from: data) {
            decoded = table
        }
        catalog = decoded
        return decoded
    }
}

public struct BrandShape: Shape {
    let layers: [Path]
    let viewBox: CGRect
    public let evenOdd: Bool
    private let layer: Int?

    public init(_ data: BrandGlyphData) {
        layers = data.paths.compactMap { SVGPath.path(from: $0) }
        if data.viewBox.count == 4, data.viewBox[2] > 0, data.viewBox[3] > 0 {
            viewBox = CGRect(x: data.viewBox[0], y: data.viewBox[1], width: data.viewBox[2], height: data.viewBox[3])
        } else {
            viewBox = CGRect(x: 0, y: 0, width: 24, height: 24)
        }
        evenOdd = data.evenOdd
        layer = nil
    }

    private init(layers: [Path], viewBox: CGRect, evenOdd: Bool, layer: Int) {
        self.layers = layers
        self.viewBox = viewBox
        self.evenOdd = evenOdd
        self.layer = layer
    }

    var layerCount: Int { layers.count }

    /// One path on its own, so overlapping elements are filled separately as SVG does.
    func only(_ index: Int) -> BrandShape {
        BrandShape(layers: layers, viewBox: viewBox, evenOdd: evenOdd, layer: index)
    }

    public func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / viewBox.width, rect.height / viewBox.height)
        let offsetX = rect.minX + (rect.width - viewBox.width * scale) / 2
        let offsetY = rect.minY + (rect.height - viewBox.height * scale) / 2
        let transform = CGAffineTransform(translationX: offsetX, y: offsetY)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -viewBox.minX, y: -viewBox.minY)
        var result = Path()
        for (index, path) in layers.enumerated() where layer == nil || layer == index {
            result.addPath(path, transform: transform)
        }
        return result
    }
}

struct BrandMark: View {
    let shape: BrandShape

    var body: some View {
        ZStack {
            ForEach(0..<shape.layerCount, id: \.self) { index in
                shape.only(index).fill(style: FillStyle(eoFill: shape.evenOdd))
            }
        }
    }
}

public struct Glyph: View {
    let symbol: String
    let fallback: String
    let size: CGFloat
    let weight: Font.Weight

    public init(symbol: String, fallback: String = "terminal", size: CGFloat = 12, weight: Font.Weight = .regular) {
        self.symbol = symbol
        self.fallback = fallback
        self.size = size
        self.weight = weight
    }

    public var body: some View {
        if let key = BrandIcons.key(in: symbol) {
            if let shape = BrandIcons.shape(key) {
                BrandMark(shape: shape).frame(width: size, height: size)
            } else {
                Image(systemName: fallback).font(.system(size: size, weight: weight))
            }
        } else {
            Image(systemName: symbol).font(.system(size: size, weight: weight))
        }
    }
}

public struct ProgramGlyph: View {
    let program: RunningProgram
    let size: CGFloat

    public init(_ program: RunningProgram, size: CGFloat) {
        self.program = program
        self.size = size
    }

    public var body: some View {
        Group {
            if let key = program.iconKey, let shape = BrandIcons.shape(key) {
                BrandMark(shape: shape)
            } else {
                Image(systemName: program.symbol).font(.system(size: size * 0.9))
            }
        }
        .frame(width: size, height: size)
    }
}
