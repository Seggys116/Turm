import Foundation
import Testing
@testable import TurmCore

struct GraphicHoldResumeTests {
    private func pieces(of chunks: [[UInt8]]) -> [TerminalGraphics.Piece] {
        var hold = GraphicHold()
        var result: [TerminalGraphics.Piece] = []
        for chunk in chunks {
            guard let ready = hold.intake(chunk) else { continue }
            let split = TerminalGraphics.split(ready)
            result += split.pieces
            hold.hold(split.remainder)
        }
        return merged(result)
    }

    private func merged(_ pieces: [TerminalGraphics.Piece]) -> [TerminalGraphics.Piece] {
        var result: [TerminalGraphics.Piece] = []
        for piece in pieces {
            if case .bytes(let more) = piece, case .bytes(let last)? = result.last {
                result[result.count - 1] = .bytes(last + more)
            } else {
                result.append(piece)
            }
        }
        return result
    }

    private let stream = Array(
        "ab\u{1B}Pq#1~~~-~~\u{1B}\\cd\u{1B}]1337;File=inline=1:AAAA\u{07}ef\u{1B}Pq#2~\u{18}gh\u{1B}]1337;File=:BB\u{1B}\\ij".utf8
    )

    @Test func splittingAtAnyOneByteBoundaryGivesTheUnsplitPieces() {
        let whole = pieces(of: [stream])
        for cut in 0...stream.count {
            #expect(pieces(of: [Array(stream[..<cut]), Array(stream[cut...])]) == whole)
        }
    }

    @Test func splittingAtAnyTwoBoundariesGivesTheUnsplitPieces() {
        let whole = pieces(of: [stream])
        for first in 0...stream.count {
            for second in first...stream.count {
                let chunks = [stream[..<first], stream[first..<second], stream[second...]].map { Array($0) }
                #expect(pieces(of: chunks) == whole)
            }
        }
    }

    @Test func feedingOneByteAtATimeGivesTheUnsplitPieces() {
        #expect(pieces(of: stream.map { [$0] }) == pieces(of: [stream]))
    }

    @Test func aLargeSixelArrivingInReadsComesOutWhole() {
        let body = [UInt8](repeating: 0x7E, count: 2_000_000)
        let image = [0x1B, 0x50, 0x71] + body + [0x1B, 0x5C]
        let full = [0x61] + image + [0x62]
        let chunks = stride(from: 0, to: full.count, by: 65_536).map { Array(full[$0..<min($0 + 65_536, full.count)]) }
        let result = pieces(of: chunks)
        #expect(result.count == 3)
        guard result.count == 3, case .sixel(let sixel) = result[1] else { return }
        #expect(Array(sixel) == image)
    }
}
