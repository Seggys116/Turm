import Testing
@testable import TurmCore

struct NewlineEncoderTests {
    private func seq(_ string: String) -> [UInt8] {
        Array(string.utf8)
    }

    @Test(arguments: [1, 3, 8, 9, 31])
    func shiftReturnUsesCsiUWhenKittyEscapesReturn(flags: Int) {
        #expect(NewlineEncoder.shiftReturn(kittyFlags: flags) == seq("\u{1B}[13;2u"))
    }

    @Test(arguments: [0, 2, 4, 16, 22])
    func shiftReturnIsCarriageReturnWithoutDisambiguation(flags: Int) {
        #expect(NewlineEncoder.shiftReturn(kittyFlags: flags) == [0x0D])
    }

    @Test func optionAddsToModifierParameterOrEscapePrefix() {
        #expect(NewlineEncoder.shiftReturn(kittyFlags: 1, alt: true) == seq("\u{1B}[13;4u"))
        #expect(NewlineEncoder.shiftReturn(kittyFlags: 0, alt: true) == [0x1B, 0x0D])
    }

    @Test func insertNewlineFallsBackToEscapeReturn() {
        #expect(NewlineEncoder.insertNewline(kittyFlags: 0) == [0x1B, 0x0D])
        #expect(NewlineEncoder.insertNewline(kittyFlags: 2) == [0x1B, 0x0D])
    }

    @Test func insertNewlineMatchesShiftReturnUnderKitty() {
        #expect(NewlineEncoder.insertNewline(kittyFlags: 1) == seq("\u{1B}[13;2u"))
        #expect(NewlineEncoder.insertNewline(kittyFlags: 8) == NewlineEncoder.shiftReturn(kittyFlags: 8))
    }

    @Test func keyBarNewlineUsesKittyFlags() {
        #expect(KeyBarEncoder.bytes(for: .newline, modifiers: [], applicationCursor: false) == [0x1B, 0x0D])
        #expect(KeyBarEncoder.bytes(for: .newline, modifiers: [], applicationCursor: false, kittyFlags: 1) == seq("\u{1B}[13;2u"))
    }

    @Test func newlineKeyIsInCatalogAndDefaults() {
        #expect(TerminalKey.key(withID: "newline")?.kind == .newline)
        #expect(TerminalKey.defaultIDs.contains("newline"))
        #expect(Set(TerminalKey.catalog.map(\.id)).count == TerminalKey.catalog.count)
    }
}
