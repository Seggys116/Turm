import Foundation
import Testing
@testable import Turm

struct KittyKeyboardTests {
    private let disambiguate = 1
    private let events = 2
    private let alternates = 4
    private let allKeys = 8
    private let textFlag = 16

    private func key(_ code: UInt16, _ chars: String = "", _ plain: String? = nil,
                     shift: Bool = false, control: Bool = false, option: Bool = false,
                     command: Bool = false, caps: Bool = false, num: Bool = false,
                     event: KeyEventType = .press, shifted: String? = nil) -> KeyInput {
        KeyInput(keyCode: code, characters: chars, unmodified: plain ?? chars,
                 shift: shift, control: control, option: option, command: command,
                 capsLock: caps, numLock: num, event: event, shifted: shifted)
    }

    private func out(_ key: KeyInput, _ flags: Int, appCursor: Bool = false) -> String? {
        let modes = KeyModes(applicationCursor: appCursor, kittyFlags: flags)
        guard let bytes = KeyEncoder.encode(key, modes: modes) else { return nil }
        return String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "\u{1B}", with: "ESC")
    }

    @Test func flagAccessors() {
        let modes = KeyModes(kittyFlags: 31)
        #expect(modes.disambiguate && modes.reportEvents && modes.reportAlternates)
        #expect(modes.reportAllKeys && modes.reportText && modes.escapeMode)
        #expect(!KeyModes(kittyFlags: 2).escapeMode)
        #expect(!KeyModes(kittyFlags: 4).escapeMode)
        #expect(!KeyModes(kittyFlags: 16).escapeMode)
        #expect(KeyModes(kittyFlags: 1).escapeMode && KeyModes(kittyFlags: 8).escapeMode)
    }

    @Test func legacyIgnoresEventsAndLocks() {
        #expect(out(key(0, "a", event: .release), 0) == nil)
        #expect(out(key(0, "a", event: .repeated), 0) == "a")
        #expect(out(key(126, caps: true), 0) == "ESC[A")
        #expect(out(key(0, "a", caps: true, num: true), 0) == "a")
    }

    @Test func legacyControlAndAlt() {
        #expect(out(key(49, " ", control: true), 0) == "\u{0}")
        #expect(out(key(49, " ", option: true), 0) == "ESC ")
        #expect(out(key(53, option: true), 0) == "ESCESC")
        #expect(out(key(36, option: true), 0) == "ESC\r")
        #expect(out(key(51, control: true), 0) == "\u{08}")
        #expect(out(key(51), 0) == "\u{7F}")
        #expect(out(key(51, option: true), 0) == "ESC\u{7F}")
        #expect(out(key(48, shift: true, option: true), 0) == "ESCESC[Z")
        #expect(out(key(11, "∫", "b", shift: true, option: true, shifted: "B"), 0) == "ESCB")
    }

    @Test func disambiguateEscapeAndModifiedSpecials() {
        #expect(out(key(53), 1) == "ESC[27u")
        #expect(out(key(53, shift: true), 1) == "ESC[27;2u")
        #expect(out(key(36), 1) == "\r")
        #expect(out(key(36, control: true), 1) == "ESC[13;5u")
        #expect(out(key(48), 1) == "\t")
        #expect(out(key(48, shift: true), 1) == "ESC[9;2u")
        #expect(out(key(51), 1) == "\u{7F}")
        #expect(out(key(51, control: true), 1) == "ESC[127;5u")
        #expect(out(key(51, option: true), 1) == "ESC[127;3u")
    }

    @Test func disambiguateTextKeys() {
        #expect(out(key(0, "a"), 1) == "a")
        #expect(out(key(0, "A", "a", shift: true), 1) == "A")
        #expect(out(key(0, "a", control: true), 1) == "ESC[97;5u")
        #expect(out(key(0, "å", "a", option: true), 1) == "ESC[97;3u")
        #expect(out(key(0, "a", control: true, option: true, shifted: nil), 1) == "ESC[97;7u")
        #expect(out(key(0, "A", "a", shift: true, control: true), 1) == "ESC[97;6u")
    }

    @Test func reportAllKeysEncodesEverything() {
        #expect(out(key(0, "a"), 8) == "ESC[97u")
        #expect(out(key(0, "A", "a", shift: true), 8) == "ESC[97;2u")
        #expect(out(key(36), 8) == "ESC[13u")
        #expect(out(key(48), 8) == "ESC[9u")
        #expect(out(key(51), 8) == "ESC[127u")
        #expect(out(key(53), 8) == "ESC[27u")
        #expect(out(key(48, shift: true), 8) == "ESC[9;2u")
        #expect(out(key(49, " "), 8) == "ESC[32u")
    }

    @Test func functionalKeysWithoutFlags() {
        #expect(out(key(126), 0) == "ESC[A")
        #expect(out(key(126), 0, appCursor: true) == "ESCOA")
        #expect(out(key(126, shift: true), 0, appCursor: true) == "ESC[1;2A")
        #expect(out(key(115), 0) == "ESC[H")
        #expect(out(key(119, control: true), 0) == "ESC[1;5F")
        #expect(out(key(122), 0) == "ESCOP")
        #expect(out(key(99, shift: true), 0) == "ESC[1;2R")
        #expect(out(key(96), 0) == "ESC[15~")
        #expect(out(key(111, shift: true), 0) == "ESC[24;2~")
        #expect(out(key(114), 0) == "ESC[2~")
        #expect(out(key(117, control: true, option: true), 0) == "ESC[3;7~")
        #expect(out(key(105), 0) == "ESC[25~")
        #expect(out(key(90), 0) == "ESC[34~")
        #expect(out(key(110), 0) == "ESC[29~")
    }

    @Test func functionalKeysInKittyMode() {
        #expect(out(key(122), 1) == "ESC[P")
        #expect(out(key(120), 1) == "ESC[Q")
        #expect(out(key(99), 1) == "ESC[13~")
        #expect(out(key(99, control: true), 1) == "ESC[13;5~")
        #expect(out(key(118, shift: true), 1) == "ESC[1;2S")
        #expect(out(key(122), 2) == "ESCOP")
        #expect(out(key(96), 1) == "ESC[15~")
        #expect(out(key(96, shift: true), 1) == "ESC[15;2~")
        #expect(out(key(126), 1, appCursor: true) == "ESCOA")
        #expect(out(key(105), 1) == "ESC[57376u")
        #expect(out(key(107), 8) == "ESC[57377u")
        #expect(out(key(113, shift: true), 1) == "ESC[57378;2u")
        #expect(out(key(106), 1) == "ESC[57379u")
        #expect(out(key(64), 1) == "ESC[57380u")
        #expect(out(key(79), 1) == "ESC[57381u")
        #expect(out(key(80), 1) == "ESC[57382u")
        #expect(out(key(90), 1) == "ESC[57383u")
        #expect(out(key(110), 1) == "ESC[57363u")
        #expect(out(key(114), 8) == "ESC[2~")
    }

    @Test func reportEventsOnFunctionalKeys() {
        #expect(out(key(126), events) == "ESC[A")
        #expect(out(key(126, event: .repeated), events) == "ESC[1;1:2A")
        #expect(out(key(126, event: .release), events) == "ESC[1;1:3A")
        #expect(out(key(126, control: true, event: .release), events) == "ESC[1;5:3A")
        #expect(out(key(117, event: .release), events) == "ESC[3;1:3~")
        #expect(out(key(117, shift: true, event: .repeated), events) == "ESC[3;2:2~")
        #expect(out(key(122, event: .release), events | disambiguate) == "ESC[1;1:3P")
        #expect(out(key(99, event: .repeated), events | disambiguate) == "ESC[13;1:2~")
        #expect(out(key(105, event: .release), events | disambiguate) == "ESC[57376;1:3u")
        #expect(out(key(126, event: .release), 0) == nil)
    }

    @Test func reportEventsRulesForEnterTabBackspace() {
        let flags = events | disambiguate
        #expect(out(key(36), flags) == "\r")
        #expect(out(key(36, event: .repeated), flags) == "\r")
        #expect(out(key(36, event: .release), flags) == nil)
        #expect(out(key(48, event: .release), flags) == nil)
        #expect(out(key(51, event: .repeated), flags) == "\u{7F}")
        #expect(out(key(51, event: .release), flags) == nil)
        #expect(out(key(36, shift: true, event: .release), flags) == "ESC[13;2:3u")
        #expect(out(key(36), events) == "\r")
        #expect(out(key(36, event: .release), events) == nil)
    }

    @Test func reportEventsRulesForEscape() {
        let flags = events | disambiguate
        #expect(out(key(53), flags) == "ESC[27u")
        #expect(out(key(53, event: .repeated), flags) == "ESC[27;1:2u")
        #expect(out(key(53, event: .release), flags) == "ESC[27;1:3u")
        #expect(out(key(53, event: .release), events) == nil)
        #expect(out(key(53, event: .repeated), events) == "ESC")
    }

    @Test func reportEventsOnTextKeys() {
        #expect(out(key(0, "a"), events) == "a")
        #expect(out(key(0, "a", event: .repeated), events) == "a")
        #expect(out(key(0, "a", event: .release), events) == nil)
        #expect(out(key(0, "a", event: .release), events | disambiguate) == nil)
        #expect(out(key(0, "a", control: true, event: .release), events | disambiguate) == "ESC[97;5:3u")
        #expect(out(key(0, "a", control: true, event: .repeated), events | disambiguate) == "ESC[97;5:2u")
        #expect(out(key(0, "a"), events | allKeys) == "ESC[97u")
        #expect(out(key(0, "a", event: .repeated), events | allKeys) == "ESC[97;1:2u")
        #expect(out(key(0, "a", event: .release), events | allKeys) == "ESC[97;1:3u")
        #expect(out(key(36, event: .release), events | allKeys) == "ESC[13;1:3u")
        #expect(out(key(51, event: .repeated), events | allKeys) == "ESC[127;1:2u")
        #expect(out(key(0, "A", "a", shift: true, event: .release), events | allKeys) == "ESC[97;2:3u")
    }

    @Test func eventsAreIgnoredWithoutFlagTwo() {
        #expect(out(key(126, event: .release), allKeys) == nil)
        #expect(out(key(0, "a", event: .release), allKeys) == nil)
        #expect(out(key(0, "a", event: .repeated), allKeys) == "ESC[97u")
        #expect(out(key(126, event: .repeated), disambiguate) == "ESC[A")
    }

    @Test func alternateKeys() {
        let flags = disambiguate | alternates
        #expect(out(key(0, "a", control: true), flags) == "ESC[97;5u")
        #expect(out(key(0, "A", "a", shift: true, control: true, shifted: "A"), flags) == "ESC[97:65;6u")
        #expect(out(key(8, "\u{03}", "с", control: true), flags) == "ESC[1089::99;5u")
        #expect(out(key(8, "С", "с", shift: true, control: true, shifted: "С"), flags) == "ESC[1089:1057:99;6u")
        #expect(out(key(0, "A", "a", shift: true, shifted: "A"), allKeys | alternates) == "ESC[97:65;2u")
        #expect(out(key(18, "!", "1", shift: true, shifted: "!"), allKeys | alternates) == "ESC[49:33;2u")
        #expect(out(key(0, "a"), allKeys | alternates) == "ESC[97u")
        #expect(out(key(0, "A", "a", shift: true), allKeys | alternates) == "ESC[97:65;2u")
        #expect(out(key(0, "a"), allKeys) == "ESC[97u")
        #expect(out(key(0, "A", "a", shift: true, shifted: "A"), allKeys) == "ESC[97;2u")
        #expect(out(key(36, shift: true), allKeys | alternates) == "ESC[13;2u")
        #expect(out(key(0, "A", "a", shift: true, shifted: "A"), alternates) == "A")
    }

    @Test func alternateKeysWithBaseLayoutOverride() {
        var input = key(0, "ф", "ф", control: true)
        input.base = "a"
        #expect(out(input, allKeys | alternates) == "ESC[1092::97;5u")
    }

    @Test func associatedTextEncoding() {
        let flags = allKeys | textFlag
        #expect(out(key(0, "a"), flags) == "ESC[97;;97u")
        #expect(out(key(0, "A", "a", shift: true), flags) == "ESC[97;2;65u")
        #expect(out(key(0, "a", control: true), flags) == "ESC[97;5u")
        #expect(out(key(0, "å", "a", option: true), flags) == "ESC[97;3u")
        #expect(out(key(49, " "), flags) == "ESC[32;;32u")
        #expect(out(key(36, "\r"), flags) == "ESC[13u")
        #expect(out(key(48, "\t"), flags) == "ESC[9u")
        #expect(out(key(126, "\u{F700}"), flags) == "ESC[A")
        #expect(out(key(0, "é", "e"), flags) == "ESC[101;;233u")
        #expect(out(key(0, "a"), flags | events) == "ESC[97;;97u")
        #expect(out(key(0, "a", event: .repeated), flags | events) == "ESC[97;1:2;97u")
        #expect(out(key(0, "a", event: .release), flags | events) == "ESC[97;1:3u")
        #expect(out(key(0, "a", shift: true, caps: true), flags) == "ESC[97;66;97u")
    }

    @Test func associatedTextIsIgnoredWithoutReportAll() {
        #expect(out(key(0, "a"), textFlag) == "a")
        #expect(out(key(0, "a", control: true), disambiguate | textFlag) == "ESC[97;5u")
        #expect(out(key(0, "a"), disambiguate | textFlag) == "a")
        #expect(out(key(0, "a"), allKeys) == "ESC[97u")
    }

    @Test func associatedTextMultipleCodepoints() {
        #expect(out(key(0, "ab", "a"), allKeys | textFlag) == "ESC[97;;97:98u")
    }

    @Test func specificationExamples() {
        let all = disambiguate | events | alternates | allKeys | textFlag
        #expect(out(key(0, "A", "a", shift: true, shifted: "A"), all) == "ESC[97:65;2;65u")
        #expect(out(key(53), disambiguate) == "ESC[27u")
        #expect(out(key(0, "a", control: true), disambiguate) == "ESC[97;5u")
        #expect(out(key(0, "a"), allKeys) == "ESC[97u")
    }

    @Test func lockModifiers() {
        #expect(out(key(0, "a", caps: true), allKeys) == "ESC[97;65u")
        #expect(out(key(0, "a", num: true), allKeys) == "ESC[97;129u")
        #expect(out(key(0, "a", caps: true, num: true), allKeys) == "ESC[97;193u")
        #expect(out(key(0, "a", control: true, caps: true), disambiguate) == "ESC[97;69u")
        #expect(out(key(126, caps: true), disambiguate) == "ESC[1;65A")
        #expect(out(key(126, num: true), events) == "ESC[1;129A")
        #expect(out(key(117, caps: true), disambiguate) == "ESC[3;65~")
        #expect(out(key(0, "a", caps: true), disambiguate) == "a")
        #expect(out(key(36, caps: true), disambiguate) == "\r")
        #expect(out(key(53, caps: true), disambiguate) == "ESC[27;65u")
        #expect(out(key(36, caps: true), allKeys) == "ESC[13;65u")
        #expect(out(key(0, "A", "a", shift: true, caps: true), allKeys) == "ESC[97;66u")
    }

    @Test func modifierKeysRequireReportAllKeys() {
        #expect(out(key(56, shift: true), disambiguate) == nil)
        #expect(out(key(56, shift: true), disambiguate | events) == nil)
        #expect(out(key(56, shift: true), alternates | textFlag) == nil)
        #expect(out(key(56, shift: true), 0) == nil)
        #expect(out(key(57, caps: true), disambiguate) == nil)
    }

    @Test func modifierKeyPresses() {
        #expect(out(key(56, shift: true), allKeys) == "ESC[57441;2u")
        #expect(out(key(59, control: true), allKeys) == "ESC[57442;5u")
        #expect(out(key(58, option: true), allKeys) == "ESC[57443;3u")
        #expect(out(key(55, command: true), allKeys) == "ESC[57444;9u")
        #expect(out(key(60, shift: true), allKeys) == "ESC[57447;2u")
        #expect(out(key(62, control: true), allKeys) == "ESC[57448;5u")
        #expect(out(key(61, option: true), allKeys) == "ESC[57449;3u")
        #expect(out(key(54, command: true), allKeys) == "ESC[57450;9u")
        #expect(out(key(57, caps: true), allKeys) == "ESC[57358;65u")
        #expect(out(key(71), allKeys) == "ESC[57360u")
    }

    @Test func modifierKeyReleasesAndRepeats() {
        let flags = allKeys | events
        #expect(out(key(56, event: .release), flags) == "ESC[57441;1:3u")
        #expect(out(key(56, shift: true), flags) == "ESC[57441;2u")
        #expect(out(key(59, shift: true, event: .release), flags) == "ESC[57442;2:3u")
        #expect(out(key(55, event: .release), flags) == "ESC[57444;1:3u")
        #expect(out(key(57, event: .release), flags) == "ESC[57358;1:3u")
        #expect(out(key(56, event: .release), allKeys) == nil)
    }

    @Test func modifiersCombineWithShiftedModifierKeys() {
        #expect(out(key(59, shift: true, control: true), allKeys) == "ESC[57442;6u")
        #expect(out(key(58, shift: true, control: true, option: true, command: true), allKeys) == "ESC[57443;16u")
    }

    @Test func keypadWithoutFlags() {
        #expect(out(key(87, "5"), 0) == "5")
        #expect(out(key(65, "."), 0) == ".")
        #expect(out(key(76, "\r"), 0) == "\r")
        #expect(out(key(69, "+", shift: true), 0) == "+")
    }

    @Test func keypadWithDisambiguate() {
        #expect(out(key(87, "5"), 1) == "5")
        #expect(out(key(87, "5", control: true), 1) == "ESC[57404;5u")
        #expect(out(key(76, "\r"), 1) == "\r")
        #expect(out(key(76, "\r", shift: true), 1) == "ESC[57414;2u")
    }

    @Test func keypadWithReportAllKeys() {
        let expected: [(UInt16, String, String)] = [
            (82, "0", "57399"), (83, "1", "57400"), (84, "2", "57401"), (85, "3", "57402"),
            (86, "4", "57403"), (87, "5", "57404"), (88, "6", "57405"), (89, "7", "57406"),
            (91, "8", "57407"), (92, "9", "57408"), (65, ".", "57409"), (75, "/", "57410"),
            (67, "*", "57411"), (78, "-", "57412"), (69, "+", "57413"), (76, "\r", "57414"),
            (81, "=", "57415"), (95, ",", "57416")
        ]
        for (code, chars, functionalCode) in expected {
            #expect(out(key(code, chars), allKeys) == "ESC[\(functionalCode)u")
        }
        #expect(out(key(87, "5"), allKeys | textFlag) == "ESC[57404;;53u")
        #expect(out(key(87, "5", event: .release), allKeys | events) == "ESC[57404;1:3u")
        #expect(out(key(87, "5", event: .repeated), allKeys | events) == "ESC[57404;1:2u")
        #expect(out(key(87, "5"), allKeys | alternates) == "ESC[57404u")
        #expect(out(key(69, "+", shift: true), allKeys) == "ESC[57413;2u")
    }

    @Test func emptyCharactersProduceNothing() {
        #expect(out(key(0, ""), allKeys) == nil)
        #expect(out(key(0, ""), 0) == nil)
        #expect(out(key(0, "", event: .release), allKeys | events) == nil)
    }

    @Test func flagCombinationsKeepEnterTabBackspaceLegacyUnlessAllKeys() {
        for flags in 0...31 where flags & allKeys == 0 {
            #expect(out(key(36), flags) == "\r")
            #expect(out(key(48), flags) == "\t")
            #expect(out(key(51), flags) == "\u{7F}")
        }
        for flags in 0...31 where flags & allKeys != 0 {
            #expect(out(key(36), flags) == "ESC[13u")
            #expect(out(key(48), flags) == "ESC[9u")
            #expect(out(key(51), flags) == "ESC[127u")
        }
    }

    @Test func everyFlagCombinationEncodesPlainLetterConsistently() {
        for flags in 0...31 {
            let result = out(key(0, "a"), flags)
            if flags & allKeys != 0 {
                let text = flags & textFlag != 0 ? ";;97" : ""
                #expect(result == "ESC[97\(text)u")
            } else {
                #expect(result == "a")
            }
        }
    }

    @Test func everyFlagCombinationEncodesCtrlLetter() {
        for flags in 1...31 {
            let result = out(key(0, "a", control: true), flags)
            if flags & (disambiguate | allKeys) != 0 {
                #expect(result == "ESC[97;5u")
            } else {
                #expect(result == "a")
            }
        }
    }

    @Test func releaseNeverProducesBytesForLegacyEncodedKeys() {
        for flags in 0...31 where flags & allKeys == 0 {
            #expect(out(key(0, "a", event: .release), flags) == nil)
            #expect(out(key(36, event: .release), flags) == nil)
            #expect(out(key(48, event: .release), flags) == nil)
            #expect(out(key(51, event: .release), flags) == nil)
        }
    }
}
