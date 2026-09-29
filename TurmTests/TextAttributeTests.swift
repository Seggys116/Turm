import AppKit
import Foundation
import SwiftTerm
import Testing
@testable import Turm

private func styled(_ input: String) -> NSAttributedString {
    let emulator = BlockEmulator(cols: 80, rows: 24)
    emulator.feed(Array(input.utf8))
    return NSAttributedString.terminalText(emulator.render())
}

private func attribute(_ key: NSAttributedString.Key, _ text: NSAttributedString, at index: Int = 0) -> Any? {
    text.attribute(key, at: index, effectiveRange: nil)
}

private func components(_ color: NSColor?) -> [Int]? {
    guard let rgb = color?.usingColorSpace(.sRGB) else { return nil }
    return [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { Int(($0 * 255).rounded()) }
}

struct TextAttributeTests {
    @Test func plainTextHasNoUnderlineOrBlink() {
        let text = styled("plain")
        #expect(attribute(.underlineStyle, text) == nil)
        #expect(attribute(.blink, text) == nil)
        #expect(attribute(.curlyUnderline, text) == nil)
    }

    @Test func singleUnderline() {
        let text = styled("\u{1B}[4mabc")
        #expect(attribute(.underlineStyle, text) as? Int == NSUnderlineStyle.single.rawValue)
        #expect(attribute(.curlyUnderline, text) == nil)
    }

    @Test func doubleUnderlineFromSGR21() {
        let text = styled("\u{1B}[21mabc")
        #expect(attribute(.underlineStyle, text) as? Int == NSUnderlineStyle.double.rawValue)
    }

    @Test func doubleUnderlineFromColonForm() {
        let text = styled("\u{1B}[4:2mabc")
        #expect(attribute(.underlineStyle, text) as? Int == NSUnderlineStyle.double.rawValue)
    }

    @Test func curlyUnderlineIsMarkedForCustomDrawing() {
        let text = styled("\u{1B}[4:3mabc")
        #expect(attribute(.underlineStyle, text) as? Int == NSUnderlineStyle.single.rawValue)
        #expect((attribute(.curlyUnderline, text) as? NSNumber)?.boolValue == true)
    }

    @Test func dottedUnderline() {
        let text = styled("\u{1B}[4:4mabc")
        let expected = NSUnderlineStyle([.single, .patternDot]).rawValue
        #expect(attribute(.underlineStyle, text) as? Int == expected)
    }

    @Test func dashedUnderline() {
        let text = styled("\u{1B}[4:5mabc")
        let expected = NSUnderlineStyle([.single, .patternDash]).rawValue
        #expect(attribute(.underlineStyle, text) as? Int == expected)
    }

    @Test func underlineStyleEndsWithReset() {
        let text = styled("\u{1B}[4:3mab\u{1B}[24mcd")
        #expect(attribute(.underlineStyle, text, at: 0) != nil)
        #expect(attribute(.underlineStyle, text, at: 2) == nil)
        #expect(attribute(.curlyUnderline, text, at: 2) == nil)
    }

    @Test func trueColourUnderlineColour() {
        let text = styled("\u{1B}[4m\u{1B}[58:2::255:0:0mabc")
        #expect(components(attribute(.underlineColor, text) as? NSColor) == [255, 0, 0])
    }

    @Test func indexedUnderlineColour() {
        let text = styled("\u{1B}[4m\u{1B}[58:5:196mabc")
        #expect(components(attribute(.underlineColor, text) as? NSColor) == [255, 0, 0])
    }

    @Test func underlineColourResetBySGR59() {
        let text = styled("\u{1B}[4m\u{1B}[58:2::0:255:0mab\u{1B}[59mcd")
        #expect(components(attribute(.underlineColor, text, at: 0) as? NSColor) == [0, 255, 0])
        #expect(attribute(.underlineColor, text, at: 2) == nil)
    }

    @Test func underlineColourIgnoredWithoutUnderline() {
        let text = styled("\u{1B}[58:2::255:0:0mabc")
        #expect(attribute(.underlineColor, text) == nil)
    }

    @Test func trueColourForegroundAndBackground() {
        let text = styled("\u{1B}[38;2;10;20;30;48;2;40;50;60mabc")
        #expect(components(attribute(.foregroundColor, text) as? NSColor) == [10, 20, 30])
        #expect(components(attribute(.backgroundColor, text) as? NSColor) == [40, 50, 60])
    }

    @Test func extendedPaletteColours() {
        let cube = styled("\u{1B}[38;5;196mabc")
        #expect(components(attribute(.foregroundColor, cube) as? NSColor) == [255, 0, 0])
        let grey = styled("\u{1B}[38;5;244mabc")
        #expect(components(attribute(.foregroundColor, grey) as? NSColor) == [128, 128, 128])
    }

    @Test func defaultForegroundIsAlwaysSet() {
        let text = styled("abc")
        #expect(attribute(.foregroundColor, text) is NSColor)
        #expect(attribute(.backgroundColor, text) == nil)
    }

    @Test func inverseSwapsColours() {
        let text = styled("\u{1B}[38;2;1;2;3;48;2;4;5;6;7mabc")
        #expect(components(attribute(.foregroundColor, text) as? NSColor) == [4, 5, 6])
        #expect(components(attribute(.backgroundColor, text) as? NSColor) == [1, 2, 3])
    }

    @Test func inverseWithDefaultColoursUsesThemeColours() {
        let text = styled("\u{1B}[7mabc")
        #expect(attribute(.foregroundColor, text) is NSColor)
        #expect(attribute(.backgroundColor, text) is NSColor)
    }

    @Test func boldAndItalicChangeTheFont() {
        let plain = attribute(.font, styled("a")) as? NSFont
        let bold = attribute(.font, styled("\u{1B}[1ma")) as? NSFont
        let italic = attribute(.font, styled("\u{1B}[3ma")) as? NSFont
        #expect(bold?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        #expect(plain?.fontDescriptor.symbolicTraits.contains(.bold) == false)
        #expect(italic?.fontDescriptor.symbolicTraits.contains(.italic) == true)
        #expect(plain?.isFixedPitch == true)
    }

    @Test func dimReducesAlpha() {
        let text = styled("\u{1B}[2mabc")
        let color = attribute(.foregroundColor, text) as? NSColor
        #expect(color != nil)
        #expect(abs((color?.alphaComponent ?? 1) - 0.6) < 0.001)
    }

    @Test func concealMakesTextTransparentButKeepsIt() {
        let text = styled("\u{1B}[8msecret")
        #expect(text.string == "secret")
        #expect((attribute(.foregroundColor, text) as? NSColor)?.alphaComponent == 0)
    }

    @Test func blinkIsMarked() {
        let text = styled("\u{1B}[5mab\u{1B}[25mcd")
        #expect((attribute(.blink, text, at: 0) as? NSNumber)?.boolValue == true)
        #expect(attribute(.blink, text, at: 2) == nil)
    }

    @Test func strikethrough() {
        let text = styled("\u{1B}[9mabc")
        #expect(attribute(.strikethroughStyle, text) as? Int == NSUnderlineStyle.single.rawValue)
    }

    @Test func hyperlinkKeepsTargetAndIsUnderlined() {
        let text = styled("\u{1B}]8;;https://example.com/a\u{07}link\u{1B}]8;;\u{07} after")
        #expect(attribute(.link, text, at: 0) as? URL == URL(string: "https://example.com/a"))
        #expect(attribute(.underlineStyle, text, at: 0) as? Int == NSUnderlineStyle.single.rawValue)
        #expect(attribute(.link, text, at: 6) == nil)
    }

    @Test func hyperlinkKeepsExplicitUnderlineStyle() {
        let text = styled("\u{1B}[4:3m\u{1B}]8;;https://example.com\u{07}link\u{1B}]8;;\u{07}")
        #expect((attribute(.curlyUnderline, text) as? NSNumber)?.boolValue == true)
    }

    @Test func plainTextSurvivesConversion() {
        #expect(styled("\u{1B}[4:3mone\u{1B}[0m two\r\nthree").string == "one two\nthree")
    }

    @Test func rapidBlinkIsDisplayedAsBlink() {
        let text = styled("\u{1B}[6mab\u{1B}[25mcd")
        #expect((attribute(.blink, text, at: 0) as? NSNumber)?.boolValue == true)
        #expect(attribute(.blink, text, at: 2) == nil)
    }
}

struct SGRRewriterTests {
    private func rewritten(_ input: String) -> String {
        var rewriter = SGRRewriter()
        return String(decoding: rewriter.rewrite(Array(input.utf8)), as: UTF8.self)
    }

    @Test func mapsRapidBlinkToBlink() {
        #expect(rewritten("\u{1B}[6m") == "\u{1B}[5m")
        #expect(rewritten("\u{1B}[1;6;31m") == "\u{1B}[1;5;31m")
        #expect(rewritten("\u{1B}[06m") == "\u{1B}[5m")
    }

    @Test func leavesExtendedColoursAlone() {
        for input in ["38;5;6", "48;5;6", "58;5;6", "38;2;6;6;6", "48;2;1;2;6", "38:5:6", "38:2::6:6:6", "4:6"] {
            let sequence = "\u{1B}[\(input)m"
            #expect(rewritten(sequence) == sequence)
        }
    }

    @Test func rewritesAfterExtendedColour() {
        #expect(rewritten("\u{1B}[38;5;6;6m") == "\u{1B}[38;5;6;5m")
        #expect(rewritten("\u{1B}[38;2;6;6;6;6m") == "\u{1B}[38;2;6;6;6;5m")
        #expect(rewritten("\u{1B}[38:5:6;6m") == "\u{1B}[38:5:6;5m")
    }

    @Test func ignoresNonSGRSequencesAndPlainText() {
        #expect(rewritten("\u{1B}[6n") == "\u{1B}[6n")
        #expect(rewritten("\u{1B}[?6m") == "\u{1B}[?6m")
        #expect(rewritten("6m and [6m") == "6m and [6m")
        #expect(rewritten("a\u{1B}[6mb\u{1B}[0m") == "a\u{1B}[5mb\u{1B}[0m")
    }

    @Test func carriesSequencesSplitAcrossFeeds() {
        var rewriter = SGRRewriter()
        var output = rewriter.rewrite(Array("ab\u{1B}".utf8))
        output += rewriter.rewrite(Array("[".utf8))
        output += rewriter.rewrite(Array("6".utf8))
        output += rewriter.rewrite(Array("mcd".utf8))
        #expect(String(decoding: output, as: UTF8.self) == "ab\u{1B}[5mcd")
    }

    @Test func splitExtendedColourIsStillProtected() {
        var rewriter = SGRRewriter()
        var output = rewriter.rewrite(Array("\u{1B}[38;5;".utf8))
        output += rewriter.rewrite(Array("6m".utf8))
        #expect(String(decoding: output, as: UTF8.self) == "\u{1B}[38;5;6m")
    }
}
