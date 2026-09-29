import CoreGraphics
import Foundation
import Testing
import SwiftTerm
@testable import Turm

struct MouseReportingTests {
    private let grid = MouseGrid(cols: 80, rows: 24, cellWidth: 10, cellHeight: 20)

    private func encode(_ action: MouseAction, _ button: MouseButton?, tracking: MouseTracking = .any,
                        encoding: MouseEncoding = .sgr, modifiers: MouseModifiers = [],
                        x: CGFloat = 25, y: CGFloat = 70, grid: MouseGrid? = nil) -> [UInt8]? {
        let event = MouseEvent(action: action, button: button, modifiers: modifiers, x: x, y: y)
        return MouseEncoder.encode(event, tracking: tracking, encoding: encoding, grid: grid ?? self.grid)
    }

    private func text(_ bytes: [UInt8]?) -> String? {
        bytes.map { String(decoding: $0, as: UTF8.self).replacingOccurrences(of: "\u{1B}", with: "ESC") }
    }

    @Test func offReportsNothing() {
        #expect(encode(.press, .left, tracking: .off) == nil)
        #expect(encode(.motion, nil, tracking: .off) == nil)
    }

    @Test func sgrPressAndReleaseKeepTheButton() {
        #expect(text(encode(.press, .left)) == "ESC[<0;3;4M")
        #expect(text(encode(.release, .left)) == "ESC[<0;3;4m")
        #expect(text(encode(.press, .middle)) == "ESC[<1;3;4M")
        #expect(text(encode(.release, .middle)) == "ESC[<1;3;4m")
        #expect(text(encode(.press, .right)) == "ESC[<2;3;4M")
        #expect(text(encode(.release, .right)) == "ESC[<2;3;4m")
    }

    @Test func defaultEncodingUsesBytesAndReleaseCodeThree() {
        #expect(encode(.press, .left, encoding: .x10) == [0x1B, 0x5B, 0x4D, 32, 35, 36])
        #expect(encode(.press, .right, encoding: .x10) == [0x1B, 0x5B, 0x4D, 34, 35, 36])
        #expect(encode(.release, .right, encoding: .x10) == [0x1B, 0x5B, 0x4D, 35, 35, 36])
    }

    @Test func defaultEncodingDropsOutOfRangeCoordinates() {
        let wide = MouseGrid(cols: 400, rows: 24, cellWidth: 10, cellHeight: 20)
        #expect(encode(.press, .left, encoding: .x10, x: 2235, grid: wide) == nil)
        #expect(encode(.press, .left, encoding: .x10, x: 2225, grid: wide) != nil)
    }

    @Test func utf8EncodingExtendsCoordinates() {
        let wide = MouseGrid(cols: 400, rows: 24, cellWidth: 10, cellHeight: 20)
        let bytes = encode(.press, .left, encoding: .utf8, x: 2995, grid: wide)
        #expect(bytes == [0x1B, 0x5B, 0x4D, 32, 0xC5, 0x8C, 36])
        #expect(encode(.press, .left, encoding: .utf8) == [0x1B, 0x5B, 0x4D, 32, 35, 36])
        #expect(encode(.release, .left, encoding: .utf8) == [0x1B, 0x5B, 0x4D, 35, 35, 36])
    }

    @Test func utf8EncodingRejectsBeyondTwoByteRange() {
        let huge = MouseGrid(cols: 3000, rows: 24, cellWidth: 1, cellHeight: 20)
        #expect(encode(.press, .left, encoding: .utf8, x: 2500, grid: huge) == nil)
    }

    @Test func urxvtEncodingUsesDecimals() {
        #expect(text(encode(.press, .left, encoding: .urxvt)) == "ESC[32;3;4M")
        #expect(text(encode(.release, .left, encoding: .urxvt)) == "ESC[35;3;4M")
        #expect(text(encode(.press, .right, encoding: .urxvt, modifiers: .control)) == "ESC[50;3;4M")
    }

    @Test func sgrPixelsReportPixelPositions() {
        #expect(text(encode(.press, .left, encoding: .sgrPixels, x: 25, y: 70)) == "ESC[<0;25;70M")
        #expect(text(encode(.release, .left, encoding: .sgrPixels, x: 25, y: 70)) == "ESC[<0;25;70m")
        let retina = MouseGrid(cols: 80, rows: 24, cellWidth: 10, cellHeight: 20, scale: 2)
        #expect(text(encode(.press, .left, encoding: .sgrPixels, x: 25, y: 70, grid: retina)) == "ESC[<0;50;140M")
    }

    @Test func sgrPixelsClampToTheGrid() {
        #expect(text(encode(.press, .left, encoding: .sgrPixels, x: 5000, y: 5000)) == "ESC[<0;799;479M")
        #expect(text(encode(.press, .left, encoding: .sgrPixels, x: -50, y: -50)) == "ESC[<0;0;0M")
    }

    @Test func x10TrackingReportsPressOnlyWithoutModifiers() {
        #expect(encode(.press, .left, tracking: .x10, encoding: .x10, modifiers: [.shift, .control]) == [0x1B, 0x5B, 0x4D, 32, 35, 36])
        #expect(encode(.release, .left, tracking: .x10) == nil)
        #expect(encode(.motion, .left, tracking: .x10) == nil)
        #expect(encode(.motion, nil, tracking: .x10) == nil)
    }

    @Test func normalTrackingReportsPressAndReleaseButNotMotion() {
        #expect(text(encode(.press, .left, tracking: .normal)) == "ESC[<0;3;4M")
        #expect(text(encode(.release, .left, tracking: .normal)) == "ESC[<0;3;4m")
        #expect(encode(.motion, .left, tracking: .normal) == nil)
        #expect(encode(.motion, nil, tracking: .normal) == nil)
    }

    @Test func buttonTrackingReportsDragOnly() {
        #expect(text(encode(.motion, .left, tracking: .button)) == "ESC[<32;3;4M")
        #expect(text(encode(.motion, .right, tracking: .button)) == "ESC[<34;3;4M")
        #expect(encode(.motion, nil, tracking: .button) == nil)
    }

    @Test func anyTrackingReportsBareMotion() {
        #expect(text(encode(.motion, nil, tracking: .any)) == "ESC[<35;3;4M")
        #expect(text(encode(.motion, .middle, tracking: .any)) == "ESC[<33;3;4M")
        #expect(text(encode(.motion, nil, tracking: .any, encoding: .x10)) == "ESC[M\u{43}#$")
        #expect(text(encode(.motion, nil, tracking: .any, encoding: .urxvt)) == "ESC[67;3;4M")
    }

    @Test func wheelUsesButtonsSixtyFourToSixtySeven() {
        #expect(text(encode(.press, .wheelUp)) == "ESC[<64;3;4M")
        #expect(text(encode(.press, .wheelDown)) == "ESC[<65;3;4M")
        #expect(text(encode(.press, .wheelLeft)) == "ESC[<66;3;4M")
        #expect(text(encode(.press, .wheelRight)) == "ESC[<67;3;4M")
        #expect(text(encode(.press, .wheelDown, encoding: .urxvt)) == "ESC[97;3;4M")
        #expect(encode(.press, .wheelUp, encoding: .x10) == [0x1B, 0x5B, 0x4D, 96, 35, 36])
    }

    @Test func wheelHasNoReleaseOrMotion() {
        #expect(encode(.release, .wheelUp) == nil)
        #expect(encode(.motion, .wheelUp) == nil)
    }

    @Test func wheelIsReportedInEveryTrackingMode() {
        for tracking in [MouseTracking.x10, .normal, .button, .any] {
            #expect(encode(.press, .wheelUp, tracking: tracking) != nil)
        }
    }

    @Test func modifiersSetBitsFourEightSixteen() {
        #expect(text(encode(.press, .left, modifiers: .shift)) == "ESC[<4;3;4M")
        #expect(text(encode(.press, .left, modifiers: .alt)) == "ESC[<8;3;4M")
        #expect(text(encode(.press, .left, modifiers: .control)) == "ESC[<16;3;4M")
        #expect(text(encode(.press, .left, modifiers: [.shift, .alt, .control])) == "ESC[<28;3;4M")
        #expect(text(encode(.release, .right, modifiers: .control)) == "ESC[<18;3;4m")
        #expect(text(encode(.motion, .left, modifiers: .alt)) == "ESC[<40;3;4M")
        #expect(text(encode(.press, .wheelUp, modifiers: .control)) == "ESC[<80;3;4M")
    }

    @Test func modifiersOnDefaultReleaseCombineWithCodeThree() {
        #expect(encode(.release, .left, encoding: .x10, modifiers: .control) == [0x1B, 0x5B, 0x4D, 32 + 19, 35, 36])
    }

    @Test func cellsAreOneBasedAndClampedToTheGrid() {
        #expect(text(encode(.press, .left, x: 0, y: 0)) == "ESC[<0;1;1M")
        #expect(text(encode(.press, .left, x: 9.9, y: 19.9)) == "ESC[<0;1;1M")
        #expect(text(encode(.press, .left, x: 10, y: 20)) == "ESC[<0;2;2M")
        #expect(text(encode(.press, .left, x: 10_000, y: 10_000)) == "ESC[<0;80;24M")
        #expect(text(encode(.press, .left, x: -30, y: -30)) == "ESC[<0;1;1M")
        #expect(text(encode(.press, .left, x: .nan, y: .infinity)) == "ESC[<0;1;1M")
    }

    @Test func encodingsMapFromPrivateModes() {
        #expect(MouseEncoding(privateMode: 1005) == .utf8)
        #expect(MouseEncoding(privateMode: 1006) == .sgr)
        #expect(MouseEncoding(privateMode: 1015) == .urxvt)
        #expect(MouseEncoding(privateMode: 1016) == .sgrPixels)
        #expect(MouseEncoding(privateMode: 1000) == nil)
    }

    @Test func trackingMapsFromTerminalModes() {
        #expect(MouseTracking(.off) == .off)
        #expect(MouseTracking(.x10) == .x10)
        #expect(MouseTracking(.vt200) == .normal)
        #expect(MouseTracking(.buttonEventTracking) == .button)
        #expect(MouseTracking(.anyEvent) == .any)
    }

    @Test func wheelAccumulatorConvertsTrackpadDistanceToSteps() {
        var wheel = WheelAccumulator()
        #expect(wheel.steps(delta: 7, unit: 20) == 0)
        #expect(wheel.steps(delta: 7, unit: 20) == 0)
        #expect(wheel.steps(delta: 7, unit: 20) == 1)
        #expect(wheel.steps(delta: 45, unit: 20) == 2)
        #expect(wheel.steps(delta: -5, unit: 20) == 0)
        #expect(wheel.steps(delta: -40, unit: 20) == -2)
    }

    @Test func wheelAccumulatorDropsRemainderWhenDirectionFlips() {
        var wheel = WheelAccumulator()
        #expect(wheel.steps(delta: 15, unit: 20) == 0)
        #expect(wheel.steps(delta: -15, unit: 20) == 0)
        #expect(wheel.steps(delta: -4, unit: 20) == 0)
        #expect(wheel.steps(delta: -4, unit: 20) == -1)
    }

    @Test func wheelAccumulatorResetsAndIgnoresInvalidInput() {
        var wheel = WheelAccumulator()
        _ = wheel.steps(delta: 15, unit: 20)
        wheel.reset()
        #expect(wheel.steps(delta: 10, unit: 20) == 0)
        #expect(wheel.steps(delta: .nan, unit: 20) == 0)
        #expect(wheel.steps(delta: 10, unit: 0) == 0)
    }
}
