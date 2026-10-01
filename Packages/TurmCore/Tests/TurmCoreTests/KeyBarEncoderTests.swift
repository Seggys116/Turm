import Testing
@testable import TurmCore

struct KeyBarEncoderTests {
    private func encode(_ kind: KeyKind, _ modifiers: KeyModifiers = [], app: Bool = false) -> [UInt8]? {
        KeyBarEncoder.bytes(for: kind, modifiers: modifiers, applicationCursor: app)
    }

    private func seq(_ string: String) -> [UInt8] {
        Array(string.utf8)
    }

    @Test func escapeAndTabAreSingleBytes() {
        #expect(encode(.escape) == [0x1B])
        #expect(encode(.tab) == [0x09])
    }

    @Test func altPrefixesEscape() {
        #expect(encode(.escape, .alt) == [0x1B, 0x1B])
        #expect(encode(.tab, .alt) == [0x1B, 0x09])
        #expect(encode(.text("x"), .alt) == [0x1B, 0x78])
    }

    @Test(arguments: Array(0x61...0x7A))
    func ctrlLowercaseLetters(scalar: Int) {
        let letter = String(UnicodeScalar(UInt8(scalar)))
        #expect(KeyBarEncoder.controlCode(for: letter) == UInt8(scalar - 0x60))
        #expect(encode(.text(letter), .ctrl) == [UInt8(scalar - 0x60)])
    }

    @Test(arguments: Array(0x41...0x5A))
    func ctrlUppercaseLettersMatchLowercase(scalar: Int) {
        let letter = String(UnicodeScalar(UInt8(scalar)))
        #expect(KeyBarEncoder.controlCode(for: letter) == UInt8(scalar - 0x40))
    }

    @Test(arguments: [
        ("a", UInt8(0x01)), ("c", 0x03), ("z", 0x1A), ("[", 0x1B), ("@", 0x00), (" ", 0x00),
        ("\\", 0x1C), ("]", 0x1D), ("^", 0x1E), ("_", 0x1F), ("?", 0x7F),
    ])
    func controlCodes(character: String, code: UInt8) {
        #expect(KeyBarEncoder.controlCode(for: character) == code)
        #expect(encode(.text(character), .ctrl) == [code])
    }

    @Test(arguments: ["1", "!", "é", "ab", "", "😀"])
    func controlCodeAbsent(text: String) {
        #expect(KeyBarEncoder.controlCode(for: text) == nil)
    }

    @Test func ctrlWithoutControlCodeKeepsText() {
        #expect(encode(.text("1"), .ctrl) == [0x31])
    }

    @Test func ctrlAltCombinesPrefixAndControlByte() {
        #expect(encode(.text("a"), [.ctrl, .alt]) == [0x1B, 0x01])
    }

    @Test func plainTextIsUnchanged() {
        #expect(encode(.text("|")) == [0x7C])
        #expect(KeyBarEncoder.text("a", modifiers: []) == [0x61])
    }

    @Test(arguments: ["é", "日本", "😀"])
    func multiByteTextPassesThrough(text: String) {
        #expect(encode(.text(text)) == Array(text.utf8))
        #expect(KeyBarEncoder.text(text, modifiers: []) == Array(text.utf8))
        #expect(KeyBarEncoder.text(text, modifiers: .ctrl) == Array(text.utf8))
        #expect(KeyBarEncoder.text(text, modifiers: .alt) == [0x1B] + Array(text.utf8))
    }

    @Test(arguments: [
        (Arrow.up, "A"), (Arrow.down, "B"), (Arrow.right, "C"), (Arrow.left, "D"),
    ])
    func arrowsNormalAndApplication(arrow: Arrow, final: String) {
        #expect(encode(.arrow(arrow)) == seq("\u{1B}[" + final))
        #expect(encode(.arrow(arrow), app: true) == seq("\u{1B}O" + final))
    }

    @Test(arguments: [
        (KeyModifiers.alt, "3"), (KeyModifiers.ctrl, "5"), (KeyModifiers([.alt, .ctrl]), "7"), (KeyModifiers(rawValue: 1), "2"),
        (KeyModifiers([KeyModifiers(rawValue: 1), .ctrl]), "6"), (KeyModifiers([KeyModifiers(rawValue: 1), .alt, .ctrl]), "8"),
    ])
    func modifiedArrowsUseCsiParameter(modifiers: KeyModifiers, parameter: String) {
        for (arrow, final) in [(Arrow.up, "A"), (.down, "B"), (.right, "C"), (.left, "D")] {
            let expected = seq("\u{1B}[1;" + parameter + final)
            #expect(encode(.arrow(arrow), modifiers) == expected)
            #expect(encode(.arrow(arrow), modifiers, app: true) == expected)
        }
    }

    @Test func parameterIsOnePlusModifierBits() {
        #expect(KeyModifiers().parameter == 1)
        #expect(KeyModifiers.alt.parameter == 3)
        #expect(KeyModifiers.ctrl.parameter == 5)
        #expect(KeyModifiers([.alt, .ctrl]).parameter == 7)
    }

    @Test func homeAndEnd() {
        #expect(encode(.navigation(.home)) == seq("\u{1B}[H"))
        #expect(encode(.navigation(.end)) == seq("\u{1B}[F"))
        #expect(encode(.navigation(.home), app: true) == seq("\u{1B}OH"))
        #expect(encode(.navigation(.end), app: true) == seq("\u{1B}OF"))
        #expect(encode(.navigation(.home), .ctrl) == seq("\u{1B}[1;5H"))
        #expect(encode(.navigation(.end), .alt, app: true) == seq("\u{1B}[1;3F"))
    }

    @Test func pageUpAndDown() {
        #expect(encode(.navigation(.pageUp)) == seq("\u{1B}[5~"))
        #expect(encode(.navigation(.pageDown)) == seq("\u{1B}[6~"))
        #expect(encode(.navigation(.pageUp), app: true) == seq("\u{1B}[5~"))
        #expect(encode(.navigation(.pageUp), .ctrl) == seq("\u{1B}[5;5~"))
        #expect(encode(.navigation(.pageDown), .alt) == seq("\u{1B}[6;3~"))
    }

    @Test(arguments: [(1, "P"), (2, "Q"), (3, "R"), (4, "S")])
    func functionKeysOneToFour(number: Int, final: String) {
        #expect(encode(.function(number)) == seq("\u{1B}O" + final))
        #expect(encode(.function(number), app: true) == seq("\u{1B}O" + final))
        #expect(encode(.function(number), .ctrl) == seq("\u{1B}[1;5" + final))
        #expect(encode(.function(number), [.alt, .ctrl]) == seq("\u{1B}[1;7" + final))
    }

    @Test(arguments: [
        (5, "15"), (6, "17"), (7, "18"), (8, "19"), (9, "20"), (10, "21"), (11, "23"), (12, "24"),
    ])
    func functionKeysFiveToTwelve(number: Int, code: String) {
        #expect(encode(.function(number)) == seq("\u{1B}[" + code + "~"))
        #expect(encode(.function(number), .alt) == seq("\u{1B}[" + code + ";3~"))
        #expect(encode(.function(number), .ctrl) == seq("\u{1B}[" + code + ";5~"))
    }

    @Test(arguments: [-1, 0, 13, 100])
    func functionKeysOutOfRangeAreNil(number: Int) {
        #expect(encode(.function(number)) == nil)
    }

    @Test(arguments: [KeyKind.control, .alt, .paste, .pad, .functionPage, .hideKeyboard])
    func nonKeyKindsProduceNothing(kind: KeyKind) {
        #expect(encode(kind) == nil)
        #expect(encode(kind, [.ctrl, .alt], app: true) == nil)
    }

    @Test func modifyRequiresModifiers() {
        #expect(KeyBarEncoder.modify(typed: Array("a".utf8)[...], modifiers: []) == nil)
    }

    @Test func modifyRejectsMultiCharacterInput() {
        #expect(KeyBarEncoder.modify(typed: Array("ab".utf8)[...], modifiers: .ctrl) == nil)
        #expect(KeyBarEncoder.modify(typed: [][...], modifiers: .ctrl) == nil)
        #expect(KeyBarEncoder.modify(typed: [0xFF][...], modifiers: .ctrl) == nil)
    }

    @Test func modifyAppliesCtrlAndAltToSingleCharacter() {
        #expect(KeyBarEncoder.modify(typed: Array("c".utf8)[...], modifiers: .ctrl) == [0x03])
        #expect(KeyBarEncoder.modify(typed: Array("x".utf8)[...], modifiers: .alt) == [0x1B, 0x78])
        #expect(KeyBarEncoder.modify(typed: Array("d".utf8)[...], modifiers: [.ctrl, .alt]) == [0x1B, 0x04])
        #expect(KeyBarEncoder.modify(typed: Array("é".utf8)[...], modifiers: .alt) == [0x1B, 0xC3, 0xA9])
    }
}
