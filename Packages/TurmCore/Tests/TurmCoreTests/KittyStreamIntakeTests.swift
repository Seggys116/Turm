import Foundation
import Testing

@testable import TurmCore

struct KittyStreamIntakeTests {
    private let command = KittyFixtures.apc("a=T,f=24,s=1,v=1,i=4", KittyFixtures.pixel)

    private func kinds(_ pieces: [KittyGraphicsScanner.Piece]) -> [String] {
        pieces.map { piece in
            switch piece.kind {
            case .text: return "text:" + String(decoding: piece.bytes, as: UTF8.self)
            case .graphics: return "graphics"
            case .clear: return "clear"
            }
        }
    }

    @Test func plainTextPassesStraightThrough() {
        var intake = KittyStreamIntake()
        #expect(intake.take(Array("hello".utf8)) == Array("hello".utf8))
    }

    @Test func commandSplitAcrossReadsIsJoined() {
        var intake = KittyStreamIntake()
        let first = intake.take(Array("a".utf8) + Array(command[..<10])) ?? []
        #expect(kinds(intake.split(first)) == ["text:a"])
        #expect(intake.take(Array(command[10..<20])) == nil)
        let rest = intake.take(Array(command[20...]) + Array("b".utf8)) ?? []
        #expect(kinds(intake.split(rest)) == ["graphics", "text:b"])
    }

    @Test func oversizedCommandIsDroppedUpToItsTerminator() {
        var intake = KittyStreamIntake(limit: 16)
        let opening = intake.take(Array("\u{1B}_Ga=T,f=24;".utf8)) ?? []
        #expect(intake.split(opening).isEmpty)
        #expect(intake.take(Array(repeating: UInt8(ascii: "A"), count: 32)) == nil)
        #expect(intake.isSkipping)
        #expect(intake.take(Array(repeating: UInt8(ascii: "A"), count: 8)) == nil)
        #expect(intake.take(Array("AA\u{1B}\\tail".utf8)) == Array("tail".utf8))
        #expect(!intake.isSkipping)
    }

    @Test func terminatorSplitBetweenReadsEndsTheSkip() {
        var intake = KittyStreamIntake(limit: 4)
        let opening = intake.take(Array("\u{1B}_G".utf8)) ?? []
        #expect(intake.split(opening).isEmpty)
        #expect(intake.take(Array("a=T,f=24;AAAA".utf8)) == nil)
        #expect(intake.isSkipping)
        #expect(intake.take([0x1B]) == nil)
        #expect(intake.take(Array("\\x".utf8)) == Array("x".utf8))
    }

    @Test func heldCommandUnderTheLimitWaits() {
        var intake = KittyStreamIntake()
        let opening = intake.take(Array(command.dropLast(2))) ?? []
        #expect(intake.split(opening).isEmpty)
        #expect(intake.take([0x1B]) == nil)
        #expect(!intake.isSkipping)
        let done = intake.take([0x5C]) ?? []
        #expect(kinds(intake.split(done)) == ["graphics"])
    }
}
